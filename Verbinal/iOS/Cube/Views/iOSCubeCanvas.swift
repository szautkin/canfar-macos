// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import MetalKit
import SwiftUI
import VerbinalKit

/// A cube's slice (or its moment 0) for touch (plan 47 5.2): pinch zooms
/// about the fingers, one finger pans, a double tap goes back to the whole
/// slice, a tap hides the chrome; a long press reads the spaxel under the
/// finger and, lifted, opens its spectrum. Drawn by `CubeSliceFrame`, as the
/// Mac's slice view is.
struct iOSCubeSliceCanvas: View {
    var model: CubeViewerModel
    /// Drawn instead of the channel's slice: the moment 0 map.
    var moment: CGImage?
    @Binding var chromeHidden: Bool
    /// A spaxel's spectrum was asked for.
    var onSpectrum: () -> Void

    @State private var startZoom: CGFloat?
    @State private var pressing = false

    var body: some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            ZStack {
                Color.black
                if let image = moment ?? model.sliceImage,
                   let frame = CubeSliceFrame(nx: model.nx, ny: model.ny, canvas: canvas, zoom: model.sliceZoom, pan: model.slicePan) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(frame.scale >= 2 ? .none : .medium)
                        .frame(width: CGFloat(model.nx) * frame.scale, height: CGFloat(model.ny) * frame.scale)
                        .position(x: canvas.width / 2 + model.slicePan.width, y: canvas.height / 2 + model.slicePan.height)
                    if let point = model.probePoint {
                        Circle()
                            .stroke(Color.green, lineWidth: 1.5)
                            .frame(width: 16, height: 16)
                            .position(frame.screen(ofVoxel: Double(point.x), Double(point.y)))
                            .allowsHitTesting(false)
                    }
                } else if model.document.state.isOpening {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        if case .opening(let stage, let progress) = model.document.state {
                            Text(verbatim: stage).font(.caption).foregroundStyle(.white.opacity(0.8))
                            if let progress { ProgressView(value: progress).frame(width: 160).tint(.white) }
                        }
                    }
                } else if let problem = model.document.state.problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle").foregroundStyle(.white).padding()
                }
            }
            .overlay {
                iOSCanvasTouchLayer(
                    onTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } },
                    onDoubleTap: { _ in withAnimation(.easeInOut(duration: 0.25)) { model.resetSliceView() } },
                    onManipulate: { phase in manipulate(phase) },
                    onPan: { moved in
                        model.slicePan.width += moved.width
                        model.slicePan.height += moved.height
                    },
                    onPress: { phase in press(phase, canvas: canvas) },
                    onHover: { location in hover(location, canvas: canvas) })
            }
            .onAppear { model.sliceCanvasSize = canvas }
            .onChange(of: canvas) { _, size in model.sliceCanvasSize = size }
        }
    }

    private func manipulate(_ phase: iOSCanvasTouchLayer.Manipulation) {
        switch phase {
        case .began:
            startZoom = model.sliceZoom
        case .changed(let scale, _, let centroid):
            guard let startZoom else { return }
            model.zoomSlice(to: startZoom * scale, keeping: centroid)
        case .ended:
            startZoom = nil
        }
    }

    /// The spaxel under the finger: its value and sky position as it moves;
    /// lifted, its spectrum.
    private func press(_ phase: iOSCanvasTouchLayer.Press, canvas: CGSize) {
        guard let frame = CubeSliceFrame(nx: model.nx, ny: model.ny, canvas: canvas,
                                         zoom: model.sliceZoom, pan: model.slicePan) else { return }
        switch phase {
        case .moved(let location):
            if let voxel = frame.voxel(atScreen: location) {
                Task { await model.updateCursor(x: voxel.x, y: voxel.y) }
            }
        case .lifted(let location):
            guard let index = frame.voxelIndex(atScreen: location) else { return }
            Task {
                await model.probe(x: index.x, y: index.y)
                onSpectrum()
            }
        case .cancelled:
            model.clearCursor()
        }
    }

    private func hover(_ location: CGPoint?, canvas: CGSize) {
        guard let location,
              let frame = CubeSliceFrame(nx: model.nx, ny: model.ny, canvas: canvas, zoom: model.sliceZoom, pan: model.slicePan),
              let voxel = frame.voxel(atScreen: location) else { model.clearCursor(); return }
        Task { await model.updateCursor(x: voxel.x, y: voxel.y) }
    }
}

/// The cube as a volume, ray-marched by the Mac's renderer (`Cube.metal`),
/// for touch (plan 47 5.6): one finger orbits, a pinch zooms, a tap picks the
/// channel under it. Fewer steps when the device is warm or saving power.
struct iOSCubeVolumeView: UIViewRepresentable {
    let model: CubeViewerModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        let device = MTLCreateSystemDefaultDevice()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        let coordinator = context.coordinator
        if let device, let renderer = CubeVolumeRenderer(device: device) {
            renderer.makePipeline(colorFormat: view.colorPixelFormat)
            view.delegate = renderer
            coordinator.renderer = renderer
            let model = self.model
            model.volumeRenderError = renderer.lastError
            renderer.onPickChannel = { [weak model] channel in
                MainActor.assumeIsolated { model?.setChannel(channel) }
            }
            coordinator.model = model
            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.orbited(_:)))
            let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
            for recognizer in [pan, pinch, tap] as [UIGestureRecognizer] { view.addGestureRecognizer(recognizer) }
        } else {
            model.volumeRenderError = String(localized: "No Metal GPU available for volume rendering. Use slice mode instead.")
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        let coordinator = context.coordinator
        let signature = "\(model.nx)x\(model.ny)x\(model.nz)"
        if let volume = model.volumeData, coordinator.volumeSignature != signature {
            renderer.setVolume(volume)
            renderer.setColormap(FITSRenderEngine.colormapRGBA(model.colormap))
            renderer.setTransferFunction(model.transferFunction)
            coordinator.volumeSignature = signature
            coordinator.appliedColormap = model.colormap
            model.volumeRenderError = renderer.lastError
        }
        renderer.windowLo = model.windowLo
        renderer.windowHi = model.windowHi
        renderer.density = model.density
        renderer.stretch = model.stretchIndex
        renderer.mip = model.mip
        renderer.spectralScale = model.spectralScale
        renderer.baseSteps = model.volumeSteps * Self.quality
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
    }

    /// The share of the ray-march steps to take: all when cool, fewer as the
    /// device warms or saves power.
    static var quality: Float {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 0.5 }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 1
        case .fair: return 0.75
        default: return 0.5
        }
    }

    final class Coordinator: NSObject {
        var renderer: CubeVolumeRenderer?
        weak var model: CubeViewerModel?
        var volumeSignature = ""
        var appliedColormap: FITSRenderParams.ColormapType?
        private var lastScale: CGFloat = 1

        @objc func orbited(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            renderer?.interacting = recognizer.state == .began || recognizer.state == .changed
            let moved = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            MainActor.assumeIsolated { model?.orbitCamera(dx: Float(moved.x), dy: Float(moved.y)) }
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { lastScale = 1 }
            renderer?.interacting = recognizer.state == .began || recognizer.state == .changed
            let delta = recognizer.scale / lastScale
            lastScale = recognizer.scale
            MainActor.assumeIsolated { model?.zoomCamera(Float(1 - delta)) }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let point = recognizer.location(in: view)
            renderer?.pick(ndcX: Float(point.x / view.bounds.width * 2 - 1), ndcY: Float(1 - point.y / view.bounds.height * 2))
        }
    }
}
