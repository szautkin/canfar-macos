// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import Metal
import MetalKit
import simd
import VerbinalKit

/// Matches the `CubeUniforms` struct in Cube.metal byte-for-byte.
private struct CubeUniforms {
    var invViewProj: simd_float4x4
    var inverseModel: simd_float4x4
    var window: simd_float2
    var steps: Float
    var density: Float
    var jitter: Float
    var stretch: Int32
    var mip: Int32
    var pad0: Float
}

/// `MTKViewDelegate` that ray-marches a cube's half-float 3D texture. All access
/// is on the main thread (MetalKit drives `draw(in:)` there, and SwiftUI pushes
/// parameters from `updateNSView`), so this is a plain main-thread object.
final class CubeVolumeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?

    private var dataTexture: MTLTexture?
    private var colormapTexture: MTLTexture?
    private var transferTexture: MTLTexture?

    // Box aspect: spatial-true, spectral axis user-stretched.
    private var boxScale = SIMD3<Float>(1, 1, 1)
    private var volDims = SIMD3<Int>(1, 1, 1)

    // Orbit camera.
    private var azimuth: Float = 0.7
    private var elevation: Float = 0.5
    private var distance: Float = 2.6
    private var viewportAspect: Float = 1
    private var jitter: Float = 0

    // Live parameters pushed from CubeViewerModel.
    var windowLo: Float = 0
    var windowHi: Float = 1
    var density: Float = 1
    var stretch: Int32 = 0
    var mip = false
    var interacting = false
    var spectralScale: Float = 1.5 { didSet { applyBoxScale() } }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
    }

    func makePipeline(colorFormat: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "vertex_cube"),
              let ffn = library.makeFunction(name: "fragment_cube") else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        guard let attachment = desc.colorAttachments[0] else { return }
        attachment.pixelFormat = colorFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // Premultiplied "over": the shader outputs premultiplied (acc, alpha).
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    var isReady: Bool { pipeline != nil }

    // MARK: - GPU resources

    func setVolume(_ volume: VolumeData) {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .r16Float
        desc.width = volume.nx
        desc.height = volume.ny
        desc.depth = volume.nz
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return }
        volume.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, volume.nx, volume.ny, volume.nz),
                mipmapLevel: 0,
                slice: 0,
                withBytes: base,
                bytesPerRow: volume.nx * MemoryLayout<Float16>.stride,
                bytesPerImage: volume.nx * volume.ny * MemoryLayout<Float16>.stride
            )
        }
        dataTexture = texture
        volDims = SIMD3(volume.nx, volume.ny, volume.nz)
        applyBoxScale()
    }

    /// 256×1 RGBA colormap (from the shared `FITSRenderEngine.colormapRGBA`).
    func setColormap(_ rgba: [UInt8]) {
        colormapTexture = make1DTexture(rgba: rgba)
    }

    /// Build the 256-entry alpha ramp from transfer-function control points.
    func setTransferFunction(_ points: [SIMD2<Float>]) {
        let sorted = points.sorted { $0.x < $1.x }
        guard let first = sorted.first, let last = sorted.last else { return }
        var alpha = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let x = Float(i) / 255
            var a = first.y
            if x >= last.x {
                a = last.y
            } else {
                for k in 0..<(sorted.count - 1) where x >= sorted[k].x && x < sorted[k + 1].x {
                    let span = max(sorted[k + 1].x - sorted[k].x, 1e-6)
                    let f = (x - sorted[k].x) / span
                    a = sorted[k].y * (1 - f) + sorted[k + 1].y * f
                    break
                }
            }
            alpha[i] = UInt8(max(0, min(1, a)) * 255)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 256, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return }
        alpha.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: base, bytesPerRow: 256)
        }
        transferTexture = texture
    }

    private func make1DTexture(rgba: [UInt8]) -> MTLTexture? {
        let width = rgba.count / 4
        guard width > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4)
        }
        return texture
    }

    private func applyBoxScale() {
        let m = Float(max(volDims.x, volDims.y))
        guard m > 0 else { return }
        boxScale = SIMD3(Float(volDims.x) / m, Float(volDims.y) / m, spectralScale)
    }

    // MARK: - Camera interaction

    func orbit(dx: Float, dy: Float) {
        azimuth -= dx * 0.01
        elevation = min(max(elevation + dy * 0.01, -1.4), 1.4)
    }

    func zoom(by delta: Float) {
        distance = min(max(distance * exp(delta), 0.5), 8)
    }

    private func cameraPosition() -> SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        return SIMD3(distance * ce * sin(azimuth), distance * se, distance * ce * cos(azimuth))
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportAspect = size.height > 0 ? Float(size.width / size.height) : 1
    }

    func draw(in view: MTKView) {
        guard let pipeline,
              let dataTexture, let colormapTexture, let transferTexture,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        jitter = (jitter + 17.13).truncatingRemainder(dividingBy: 1024)
        var uniforms = buildUniforms()

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CubeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(dataTexture, index: 0)
        encoder.setFragmentTexture(colormapTexture, index: 1)
        encoder.setFragmentTexture(transferTexture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func buildUniforms() -> CubeUniforms {
        let model = simd_float4x4(diagonal: SIMD4(boxScale.x, boxScale.y, boxScale.z, 1))
        let view = makeLookAt(eye: cameraPosition(), center: .zero, up: SIMD3(0, 1, 0))
        let proj = makePerspective(fovyRadians: 38 * .pi / 180, aspect: viewportAspect, near: 0.01, far: 50)
        let viewProj = proj * view
        return CubeUniforms(
            invViewProj: viewProj.inverse,
            inverseModel: model.inverse,
            window: SIMD2(windowLo, windowHi),
            steps: interacting ? 160 : 384,
            density: density,
            jitter: jitter,
            stretch: stretch,
            mip: mip ? 1 : 0,
            pad0: 0
        )
    }
}

// MARK: - Matrix helpers (column-major, Metal NDC z ∈ [0,1])

private func makePerspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tan(fovy * 0.5)
    let xs = ys / max(aspect, 0.0001)
    let zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(xs, 0, 0, 0),
        SIMD4(0, ys, 0, 0),
        SIMD4(0, 0, zs, -1),
        SIMD4(0, 0, zs * near, 0)
    ))
}

private func makeLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = normalize(eye - center)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    return simd_float4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0),
        SIMD4(x.y, y.y, z.y, 0),
        SIMD4(x.z, y.z, z.z, 0),
        SIMD4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    ))
}
#endif
