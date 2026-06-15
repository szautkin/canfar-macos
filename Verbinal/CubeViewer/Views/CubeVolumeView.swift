// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import MetalKit
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
            view.onOrbit = { dx, dy in renderer.orbit(dx: Float(dx), dy: Float(dy)) }
            view.onZoom = { delta in renderer.zoom(by: Float(delta)) }
            view.onInteractStart = { renderer.interacting = true }
            view.onInteractEnd = { renderer.interacting = false }
            view.onClickNDC = { x, y in renderer.pick(ndcX: Float(x), ndcY: Float(y)) }
            renderer.onPickChannel = { channel in
                MainActor.assumeIsolated { model.setChannel(channel) }
            }
            model.volumeSnapshot = { width, height in renderer.snapshot(width: width, height: height) }
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
        renderer.autoOrbit = model.autoOrbit

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
#endif
