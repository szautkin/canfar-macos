// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import MetalKit
import simd
import VerbinalKit

/// SwiftUI host for the Metal volume renderer. Pushes live parameters from the
/// model into the renderer on every observed change, uploads the volume +
/// colormap + transfer-function textures once per cube, and routes orbit/zoom +
/// click-to-pick interaction.
struct CubeVolumeView: NSViewRepresentable {
    let model: CubeViewerModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CubeMTKView {
        let view = CubeMTKView()
        let device = MTLCreateSystemDefaultDevice()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60

        if let device, let renderer = CubeVolumeRenderer(device: device) {
            renderer.makePipeline(colorFormat: view.colorPixelFormat)
            view.delegate = renderer
            context.coordinator.renderer = renderer
            let model = self.model
            view.onOrbit = { dx, dy in MainActor.assumeIsolated { model.orbitCamera(dx: Float(dx), dy: Float(dy)) } }
            view.onZoom = { delta in MainActor.assumeIsolated { model.zoomCamera(Float(delta)) } }
            view.onInteractStart = { renderer.interacting = true }
            view.onInteractEnd = { renderer.interacting = false }
            view.onClickNDC = { [weak renderer] x, y in renderer?.pick(ndcX: Float(x), ndcY: Float(y)) }
            renderer.onPickChannel = { [weak model] channel in
                MainActor.assumeIsolated { model?.setChannel(channel) }
            }
            // Capture the renderer weakly: this transport closure is stored on the
            // model, so a strong capture would form a model↔renderer retain cycle
            // that keeps the 3D volume texture alive after leaving volume mode.
            model.volumeSnapshot = { [weak renderer] width, height, background in
                renderer?.snapshot(width: width, height: height, distanceScale: CubeViewerConstants.exportDistanceScale, background: background)
            }
        }
        return view
    }

    func updateNSView(_ view: CubeMTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        let coordinator = context.coordinator

        // Upload the volume + textures once per distinct cube.
        let signature = "\(model.nx)x\(model.ny)x\(model.nz)"
        if let volume = model.volumeData, coordinator.volumeSignature != signature {
            renderer.setVolume(volume)
            renderer.setColormap(FITSRenderEngine.colormapRGBA(model.colormap))
            renderer.setTransferFunction(model.transferFunction)
            coordinator.volumeSignature = signature
            coordinator.appliedColormap = model.colormap
            coordinator.appliedTransfer = model.transferFunction
        }

        // Push live render parameters.
        renderer.windowLo = model.windowLo
        renderer.windowHi = model.windowHi
        renderer.density = model.density
        renderer.stretch = model.stretchIndex
        renderer.mip = model.mip
        renderer.spectralScale = model.spectralScale
        renderer.baseSteps = model.volumeSteps
        renderer.showSlicePlane = model.showSlicePlane
        renderer.sliceFraction = model.nz > 1 ? Float(model.channel) / Float(model.nz - 1) : 0
        renderer.cameraAzimuth = model.cameraAzimuth
        renderer.cameraElevation = model.cameraElevation
        renderer.cameraDistance = model.cameraDistance

        let bg = model.background.rgba
        view.clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))

        if coordinator.appliedColormap != model.colormap {
            renderer.setColormap(FITSRenderEngine.colormapRGBA(model.colormap))
            coordinator.appliedColormap = model.colormap
        }
        if coordinator.appliedTransfer != model.transferFunction {
            renderer.setTransferFunction(model.transferFunction)
            coordinator.appliedTransfer = model.transferFunction
        }
    }

    final class Coordinator {
        var renderer: CubeVolumeRenderer?
        var volumeSignature = ""
        var appliedColormap: FITSRenderParams.ColormapType?
        var appliedTransfer: [SIMD2<Float>] = []
    }
}

/// MTKView subclass that turns mouse/scroll/pinch into orbit + zoom + click-pick
/// callbacks — self-contained input capture for the volume view.
final class CubeMTKView: MTKView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onInteractStart: (() -> Void)?
    var onInteractEnd: (() -> Void)?
    var onClickNDC: ((CGFloat, CGFloat) -> Void)?

    private var lastDrag: NSPoint?
    private var dragDistance: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastDrag = event.locationInWindow
        dragDistance = 0
        onInteractStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDrag else { return }
        let point = event.locationInWindow
        dragDistance += abs(point.x - last.x) + abs(point.y - last.y)
        onOrbit?(point.x - last.x, point.y - last.y)
        lastDrag = point
    }

    override func mouseUp(with event: NSEvent) {
        if dragDistance < 4, bounds.width > 0, bounds.height > 0 {
            // NSView coords are y-up (origin bottom-left) → matches Metal NDC.
            let p = convert(event.locationInWindow, from: nil)
            onClickNDC?(2 * p.x / bounds.width - 1, 2 * p.y / bounds.height - 1)
        }
        lastDrag = nil
        onInteractEnd?()
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(-event.scrollingDeltaY * 0.01)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(-event.magnification)
    }
}

/// Axis captions for the volume box — projects RA/DEC/spectral axis names and
/// their endpoint values from the model's orbit camera (no Metal text needed).
struct CubeAxisCaptions: View {
    let model: CubeViewerModel
    /// Matches the camera pull-back used for export snapshots so labels align.
    var distanceScale: Float = 1

    private struct Caption: Identifiable { let id = UUID(); let text: String; let point: CGPoint; let accent: Bool }

    var body: some View {
        GeometryReader { geo in
            ForEach(captions(in: geo.size)) { caption in
                Text(caption.text)
                    .font(.system(size: 11, weight: caption.accent ? .semibold : .regular, design: .monospaced))
                    // Explicit colors (not .secondary) so they stay legible when
                    // ImageRenderer rasterizes in light mode for export.
                    .foregroundStyle(caption.accent ? Color(red: 0.45, green: 0.85, blue: 1.0) : Color(white: 0.96))
                    .shadow(color: .black, radius: 3)
                    .shadow(color: .black, radius: 1)
                    .position(caption.point)
            }
        }
        .allowsHitTesting(false)
    }

    private func captions(in size: CGSize) -> [Caption] {
        guard model.nz > 0, size.width > 1, size.height > 1 else { return [] }
        let m = Float(max(model.nx, model.ny))
        guard m > 0 else { return [] }
        let boxScale = SIMD3<Float>(Float(model.nx) / m, Float(model.ny) / m, model.spectralScale)
        let modelMatrix = simd_float4x4(diagonal: SIMD4(boxScale.x, boxScale.y, boxScale.z, 1))
        let view = makeLookAt(eye: cameraEye(), center: .zero, up: SIMD3(0, 1, 0))
        let proj = makePerspective(fovyRadians: 38 * .pi / 180, aspect: Float(size.width / size.height), near: 0.01, far: 50)
        let mvp = proj * view * modelMatrix

        func project(_ p: SIMD3<Float>) -> CGPoint? {
            let clip = mvp * SIMD4(p, 1)
            guard clip.w > 0.0001 else { return nil }
            let x = clip.x / clip.w, y = clip.y / clip.w
            return CGPoint(x: CGFloat(x * 0.5 + 0.5) * size.width, y: CGFloat(1 - (y * 0.5 + 0.5)) * size.height)
        }

        let frame = model.wcs?.celestial.frame
        let lon = frame == .galactic ? "GLON" : "RA"
        let lat = frame == .galactic ? "GLAT" : "DEC"
        let spec = model.wcs?.spectral.format(channel: model.channel).axisLabel ?? "CHANNEL"

        let specs: [(String, SIMD3<Float>, Bool)] = [
            (lon, SIMD3(0, -0.62, -0.62), true),
            (xEndpoint(0), SIMD3(-0.5, -0.62, -0.62), false),
            (xEndpoint(model.nx - 1), SIMD3(0.5, -0.62, -0.62), false),
            (lat, SIMD3(-0.62, 0, -0.62), true),
            (yEndpoint(0), SIMD3(-0.62, -0.5, -0.62), false),
            (yEndpoint(model.ny - 1), SIMD3(-0.62, 0.5, -0.62), false),
            (spec, SIMD3(-0.62, -0.62, 0), true),
            (zEndpoint(0), SIMD3(-0.62, -0.62, -0.5), false),
            (zEndpoint(model.nz - 1), SIMD3(-0.62, -0.62, 0.5), false),
        ]
        return specs.compactMap { text, position, accent in
            guard !text.isEmpty, let point = project(position) else { return nil }
            let clamped = CGPoint(x: min(max(point.x, 8), size.width - 8),
                                  y: min(max(point.y, 8), size.height - 8))
            return Caption(text: text, point: clamped, accent: accent)
        }
    }

    private func cameraEye() -> SIMD3<Float> {
        let d = model.cameraDistance * distanceScale
        let ce = cos(model.cameraElevation), se = sin(model.cameraElevation)
        return SIMD3(d * ce * sin(model.cameraAzimuth), d * se, d * ce * cos(model.cameraAzimuth))
    }

    private func xEndpoint(_ px: Int) -> String {
        guard let cel = model.wcs?.celestial, let sky = cel.pixelToSky(x: Double(px), y: 0) else { return "" }
        return cel.formatSky(lon: sky.lon, lat: sky.lat).lon
    }
    private func yEndpoint(_ py: Int) -> String {
        guard let cel = model.wcs?.celestial, let sky = cel.pixelToSky(x: 0, y: Double(py)) else { return "" }
        return cel.formatSky(lon: sky.lon, lat: sky.lat).lat
    }
    private func zEndpoint(_ ch: Int) -> String {
        model.wcs?.spectral.format(channel: ch).primary ?? ""
    }
}

#endif
