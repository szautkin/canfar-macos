// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import Metal
import MetalKit
import simd
import Foundation
import CoreGraphics
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

/// Matches `OverlayUniforms` in Cube.metal.
private struct OverlayUniforms {
    var mvp: simd_float4x4
    var color: simd_float4
}

/// `MTKViewDelegate` that ray-marches a cube's half-float 3D texture and draws
/// the bounding box + slice-plane overlay. All access is on the main thread
/// (MetalKit drives `draw(in:)` there; SwiftUI pushes parameters from
/// `updateNSView`), so this is a plain main-thread object.
final class CubeVolumeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var overlayPipeline: MTLRenderPipelineState?
    private var boxEdgeBuffer: MTLBuffer?

    private var dataTexture: MTLTexture?
    private var colormapTexture: MTLTexture?
    private var transferTexture: MTLTexture?

    // CPU copy of the volume for ray-picking.
    private var volumeCPU: [Float16]?
    private var volDims = SIMD3<Int>(1, 1, 1)
    private var volBinZ = 1

    // Box aspect: spatial-true, spectral axis user-stretched.
    private var boxScale = SIMD3<Float>(1, 1, 1)

    // Orbit camera — pushed from the model each frame (the model owns it so the
    // axis-caption overlay can track the orbit).
    var cameraAzimuth: Float = 0.7
    var cameraElevation: Float = 0.5
    var cameraDistance: Float = 2.6
    private var viewportAspect: Float = 1
    private var jitter: Float = 0

    // Live parameters pushed from CubeViewerModel.
    var windowLo: Float = 0
    var windowHi: Float = 1
    var density: Float = 1
    var stretch: Int32 = 0
    var mip = false
    var interacting = false
    var baseSteps: Float = 384
    var showSlicePlane = true
    var sliceFraction: Float = 0.5
    var onPickChannel: ((Int) -> Void)?
    var spectralScale: Float = 1.5 { didSet { applyBoxScale() } }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
    }

    func makePipeline(colorFormat: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary() else { return }
        if let vfn = library.makeFunction(name: "vertex_cube"),
           let ffn = library.makeFunction(name: "fragment_cube") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            if let attachment = desc.colorAttachments[0] {
                attachment.pixelFormat = colorFormat
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                // Premultiplied "over": the shader outputs premultiplied (acc, alpha).
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        if let vfn = library.makeFunction(name: "vertex_overlay"),
           let ffn = library.makeFunction(name: "fragment_overlay") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            if let attachment = desc.colorAttachments[0] {
                attachment.pixelFormat = colorFormat
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .sourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            overlayPipeline = try? device.makeRenderPipelineState(descriptor: desc)
            let edges = Self.unitBoxEdges()
            boxEdgeBuffer = device.makeBuffer(bytes: edges, length: MemoryLayout<SIMD3<Float>>.stride * edges.count, options: [])
        }
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
        volumeCPU = volume.data
        volDims = SIMD3(volume.nx, volume.ny, volume.nz)
        volBinZ = volume.binZ
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

    private func cameraPosition() -> SIMD3<Float> {
        let ce = cos(cameraElevation), se = sin(cameraElevation)
        return SIMD3(cameraDistance * ce * sin(cameraAzimuth), cameraDistance * se, cameraDistance * ce * cos(cameraAzimuth))
    }

    private func currentMatrices() -> (model: simd_float4x4, viewProj: simd_float4x4) {
        let model = simd_float4x4(diagonal: SIMD4(boxScale.x, boxScale.y, boxScale.z, 1))
        let view = makeLookAt(eye: cameraPosition(), center: .zero, up: SIMD3(0, 1, 0))
        let proj = makePerspective(fovyRadians: 38 * .pi / 180, aspect: viewportAspect, near: 0.01, far: 50)
        return (model, proj * view)
    }

    /// Ray-pick: march the CPU volume from the click ray, jump to the brightest
    /// channel (mapped back through the spectral binning).
    func pick(ndcX: Float, ndcY: Float) {
        guard let volumeCPU, let onPickChannel else { return }
        let (model, viewProj) = currentMatrices()
        let invVP = viewProj.inverse
        let invModel = model.inverse
        let near = invVP * SIMD4<Float>(ndcX, ndcY, 0, 1)
        let far = invVP * SIMD4<Float>(ndcX, ndcY, 1, 1)
        let nearW = SIMD3(near.x, near.y, near.z) / near.w
        let farW = SIMD3(far.x, far.y, far.z) / far.w
        let ro4 = invModel * SIMD4(nearW, 1)
        let ro = SIMD3(ro4.x, ro4.y, ro4.z)
        let rd4 = invModel * SIMD4(farW - nearW, 0)
        let rd = normalize(SIMD3(rd4.x, rd4.y, rd4.z))
        guard let bounds = rayBox(ro, rd) else { return }

        let (nx, ny, nz) = (volDims.x, volDims.y, volDims.z)
        let steps = 512
        var best: Float = 0
        var bestZ = -1
        for i in 0...steps {
            let t = bounds.0 + (bounds.1 - bounds.0) * Float(i) / Float(steps)
            let p = ro + rd * t + SIMD3<Float>(0.5, 0.5, 0.5)
            let px = Int(p.x * Float(nx)), py = Int(p.y * Float(ny)), pz = Int(p.z * Float(nz))
            if px < 0 || py < 0 || pz < 0 || px >= nx || py >= ny || pz >= nz { continue }
            let v = Float(volumeCPU[pz * nx * ny + py * nx + px])
            if v > best { best = v; bestZ = pz }
        }
        if bestZ >= 0 { onPickChannel(Int((Float(bestZ) + 0.5) * Float(volBinZ))) }
    }

    private func rayBox(_ o: SIMD3<Float>, _ d: SIMD3<Float>) -> (Float, Float)? {
        var tmin = -Float.infinity, tmax = Float.infinity
        for ax in 0..<3 {
            let inv = 1 / d[ax]
            var t0 = (-0.5 - o[ax]) * inv
            var t1 = (0.5 - o[ax]) * inv
            if t0 > t1 { swap(&t0, &t1) }
            tmin = max(tmin, t0); tmax = min(tmax, t1)
        }
        if tmax < max(tmin, 0) { return nil }
        return (max(tmin, 0), tmax)
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
        let (model, viewProj) = currentMatrices()
        let mvp = viewProj * model

        var uniforms = CubeUniforms(
            invViewProj: viewProj.inverse,
            inverseModel: model.inverse,
            window: SIMD2(windowLo, windowHi),
            steps: interacting ? min(160, baseSteps) : baseSteps,
            density: density,
            jitter: jitter,
            stretch: stretch,
            mip: mip ? 1 : 0,
            pad0: 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CubeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(dataTexture, index: 0)
        encoder.setFragmentTexture(colormapTexture, index: 1)
        encoder.setFragmentTexture(transferTexture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        drawOverlay(encoder, mvp: mvp)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Render one frame into an offscreen texture at the given size and read it
    /// back as a CGImage (for figure export). Full quality, no jitter.
    func snapshot(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let pipeline,
              let dataTexture, let colormapTexture, let transferTexture else { return nil }
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: texDesc),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return nil }

        let savedAspect = viewportAspect
        viewportAspect = Float(width) / Float(height)
        let (model, viewProj) = currentMatrices()
        let mvp = viewProj * model
        var uniforms = CubeUniforms(
            invViewProj: viewProj.inverse, inverseModel: model.inverse,
            window: SIMD2(windowLo, windowHi), steps: max(baseSteps, 384),
            density: density, jitter: 0, stretch: stretch, mip: mip ? 1 : 0, pad0: 0
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CubeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(dataTexture, index: 0)
        encoder.setFragmentTexture(colormapTexture, index: 1)
        encoder.setFragmentTexture(transferTexture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        drawOverlay(encoder, mvp: mvp)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        viewportAspect = savedAspect
        return Self.cgImage(from: target)
    }

    private static func cgImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        let rowBytes = w * 4
        var data = [UInt8](repeating: 0, count: rowBytes * h)
        return data.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let base = ptr.baseAddress else { return nil }
            texture.getBytes(base, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return nil }
            return ctx.makeImage()
        }
    }

    private func drawOverlay(_ encoder: MTLRenderCommandEncoder, mvp: simd_float4x4) {
        guard let overlayPipeline, let boxEdgeBuffer else { return }
        encoder.setRenderPipelineState(overlayPipeline)

        // Bounding box wireframe.
        var boxUniforms = OverlayUniforms(mvp: mvp, color: SIMD4(0.33, 0.66, 0.82, 0.7))
        encoder.setVertexBuffer(boxEdgeBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&boxUniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&boxUniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 24)

        guard showSlicePlane else { return }
        let z = sliceFraction - 0.5

        // Translucent plane fill.
        let quad = Self.planeTriangles(z)
        var fillUniforms = OverlayUniforms(mvp: mvp, color: SIMD4(0.34, 0.78, 1.0, 0.16))
        quad.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setVertexBytes(&fillUniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&fillUniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Plane edges.
        let edges = Self.planeEdges(z)
        var edgeUniforms = OverlayUniforms(mvp: mvp, color: SIMD4(0.34, 0.78, 1.0, 0.7))
        edges.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setVertexBytes(&edgeUniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&edgeUniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 8)
    }

    // MARK: - Geometry

    private static func unitBoxEdges() -> [SIMD3<Float>] {
        let p: Float = 0.5
        let c: [SIMD3<Float>] = [
            SIMD3(-p, -p, -p), SIMD3(p, -p, -p), SIMD3(p, p, -p), SIMD3(-p, p, -p),
            SIMD3(-p, -p, p), SIMD3(p, -p, p), SIMD3(p, p, p), SIMD3(-p, p, p),
        ]
        let pairs = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        var out: [SIMD3<Float>] = []
        for (a, b) in pairs { out.append(c[a]); out.append(c[b]) }
        return out
    }

    private static func planeTriangles(_ z: Float) -> [SIMD3<Float>] {
        let a = SIMD3<Float>(-0.5, -0.5, z), b = SIMD3<Float>(0.5, -0.5, z)
        let c = SIMD3<Float>(0.5, 0.5, z), d = SIMD3<Float>(-0.5, 0.5, z)
        return [a, b, c, a, c, d]
    }

    private static func planeEdges(_ z: Float) -> [SIMD3<Float>] {
        let a = SIMD3<Float>(-0.5, -0.5, z), b = SIMD3<Float>(0.5, -0.5, z)
        let c = SIMD3<Float>(0.5, 0.5, z), d = SIMD3<Float>(-0.5, 0.5, z)
        return [a, b, b, c, c, d, d, a]
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
