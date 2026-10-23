// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// The image, edge to edge, for touch (plan 47 4.1). Pinch zooms about the
/// fingers, which move it too; one finger or a scroll pans; two fingers turn
/// it (snapping to North Up); a double tap goes between Fit and 1:1; a tap
/// hides the chrome. A long press brings the loupe — the pixels under the
/// finger, magnified, with their value and sky position — and lifting the
/// finger leaves the crosshair there. With a pointer or Apple Pencil hover,
/// hovering reads the pixel too. The touches are UIKit's (`iOSCanvasTouchLayer`);
/// the drawing is the Mac's (`FITSImageView`): one viewport, one mapping.
struct iOSFITSCanvas: View {
    var model: FITSViewerModel
    var host: FITSTabHostModel
    @Binding var chromeHidden: Bool
    /// Where the person is reading now — the loupe or a hover — for the readout.
    @Binding var probe: CGPoint?

    /// The zoom and turn when two fingers came down, and the image point
    /// between them, which stays between them.
    @State private var manipulation: (zoom: Double, rotation: Double, anchor: CGPoint)?
    @State private var loupe: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            ZStack {
                Color.black
                if let image = model.renderedImage, let size = model.imageSize {
                    picture(image, size: size, canvas: canvas)
                    blinkOverlay(size: size, canvas: canvas)
                    if let crosshair = model.crosshairPixel {
                        crosshairLines(at: model.imageToScreen(crosshair, imgSize: size, canvasSize: canvas), canvas: canvas)
                    }
                    if !chromeHidden {
                        iOSCompassRose(model: model, size: size, canvas: canvas)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        iOSScaleBar(model: model)
                            .padding(.leading, 14)
                            .padding(.bottom, 64)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    if let loupe {
                        iOSLoupe(model: model, image: image, size: size,
                                 point: model.screenToImage(loupe, imgSize: size, canvasSize: canvas))
                            .position(x: loupe.x, y: max(80, loupe.y - 96))
                            .allowsHitTesting(false)
                    }
                } else if model.render.isWorking || model.document.state.isOpening {
                    ProgressView().tint(.white)
                } else if let problem = model.render.problem ?? model.document.state.problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white)
                        .padding()
                }
            }
            .overlay {
                iOSCanvasTouchLayer(
                    onTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } },
                    onDoubleTap: { location in doubleTap(at: location, canvas: canvas) },
                    onManipulate: { phase in manipulate(phase, canvas: canvas) },
                    onPan: { moved in
                        model.viewport.panX += moved.width
                        model.viewport.panY += moved.height
                    },
                    onPress: { phase in press(phase, canvas: canvas) },
                    onHover: { location in hover(location, canvas: canvas) })
            }
            .onAppear { model.lastCanvasSize = canvas }
            .onChange(of: canvas) { _, newSize in
                let wasFitted = model.isFitted(canvasSize: model.lastCanvasSize)
                model.lastCanvasSize = newSize
                if wasFitted { model.fitToWindow(canvasSize: newSize) }
            }
            .onChange(of: model.renderedImage != nil) { _, drawn in
                if drawn, model.viewport == FITSViewport() { model.fitToWindow(canvasSize: canvas) }
            }
        }
    }

    // MARK: - Drawing

    private func picture(_ image: CGImage, size: CGSize, canvas: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(model.viewport.zoom >= 2 ? .none : .medium)
            .frame(width: size.width * model.viewport.zoom, height: size.height * model.viewport.zoom)
            .scaleEffect(x: model.viewport.flipX ? -1 : 1, y: 1)
            .rotationEffect(.radians(model.viewport.rotation))
            .position(x: canvas.width / 2 + model.viewport.panX, y: canvas.height / 2 + model.viewport.panY)
            .accessibilityLabel(Text(model.displayName))
    }

    /// The other image, aligned by WCS, while the person holds Compare (the
    /// Mac's blink overlay, drawn the same way).
    @ViewBuilder
    private func blinkOverlay(size: CGSize, canvas: CGSize) -> some View {
        if host.isBlinking, let overlay = host.blinkOverlayImage {
            if let transform = host.blinkTransform {
                Image(decorative: overlay, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(x: transform.scaleX < 0 ? -1 : 1, y: 1, anchor: .center)
                    .rotationEffect(.radians(transform.rotation))
                    .scaleEffect(x: abs(transform.scaleX), y: transform.scaleY, anchor: .center)
                    .position(x: canvas.width / 2 + transform.translateX, y: canvas.height / 2 + transform.translateY)
                    .opacity(host.blinkOpacity)
                    .allowsHitTesting(false)
            } else {
                Image(decorative: overlay, scale: 1)
                    .resizable()
                    .frame(width: size.width * model.viewport.zoom, height: size.height * model.viewport.zoom)
                    .scaleEffect(x: model.viewport.flipX ? -1 : 1, y: 1)
                    .rotationEffect(.radians(model.viewport.rotation))
                    .position(x: canvas.width / 2 + model.viewport.panX, y: canvas.height / 2 + model.viewport.panY)
                    .opacity(host.blinkOpacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func crosshairLines(at point: CGPoint, canvas: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: point.y)); path.addLine(to: CGPoint(x: point.x - 10, y: point.y))
            path.move(to: CGPoint(x: point.x + 10, y: point.y)); path.addLine(to: CGPoint(x: canvas.width, y: point.y))
            path.move(to: CGPoint(x: point.x, y: 0)); path.addLine(to: CGPoint(x: point.x, y: point.y - 10))
            path.move(to: CGPoint(x: point.x, y: point.y + 10)); path.addLine(to: CGPoint(x: point.x, y: canvas.height))
        }
        .stroke(Color.green.opacity(0.85), lineWidth: 1)
        .allowsHitTesting(false)
    }

    // MARK: - Touch

    /// Pinch and turn about the fingers: the image point between them stays
    /// between them as they move; within 5° of North Up, it snaps there.
    private func manipulate(_ phase: iOSCanvasTouchLayer.Manipulation, canvas: CGSize) {
        guard let size = model.imageSize else { return }
        switch phase {
        case .began(let centroid):
            manipulation = (model.viewport.zoom, model.viewport.rotation,
                            model.screenToImage(centroid, imgSize: size, canvasSize: canvas))
        case .changed(let scale, let rotation, let centroid):
            guard let start = manipulation else { return }
            model.viewport.zoom = min(FITSViewerConstants.zoomMax, max(FITSViewerConstants.zoomMin, start.zoom * scale))
            model.viewport.rotation = start.rotation + rotation
            let centred = model.makeTransform(imgSize: size, canvasSize: canvas).panToCenter(start.anchor)
            model.viewport.panX = centred.panX + centroid.x - canvas.width / 2
            model.viewport.panY = centred.panY + centroid.y - canvas.height / 2
        case .ended:
            let turned = manipulation.map { abs($0.rotation - model.viewport.rotation) > 0.001 } ?? false
            manipulation = nil
            model.onZoomChanged?()
            guard turned, let wcs = model.wcs else { return }
            let north = -wcs.northAngle * .pi / 180
            if abs(remainder(model.viewport.rotation - north, 2 * .pi)) < 5 * .pi / 180 { model.applyNorthUp() }
        }
    }

    /// The loupe follows the finger, and the readout with it; lifting leaves
    /// the crosshair there.
    private func press(_ phase: iOSCanvasTouchLayer.Press, canvas: CGSize) {
        guard let size = model.imageSize else { return }
        func inside(_ point: CGPoint) -> Bool {
            point.x >= 0 && point.y >= 0 && point.x < size.width && point.y < size.height
        }
        switch phase {
        case .moved(let location):
            loupe = location
            probe = location
            let point = model.screenToImage(location, imgSize: size, canvasSize: canvas)
            if inside(point) { model.updateCursorInfo(at: point) }
        case .lifted(let location):
            loupe = nil
            probe = nil
            let point = model.screenToImage(location, imgSize: size, canvasSize: canvas)
            if inside(point) { model.placeCrosshair(at: point) }
        case .cancelled:
            loupe = nil
            probe = nil
        }
    }

    /// Fit ⇄ 1:1 about the tapped point.
    private func doubleTap(at location: CGPoint, canvas: CGSize) {
        guard let size = model.imageSize else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            if model.isFitted(canvasSize: canvas) {
                let point = model.screenToImage(location, imgSize: size, canvasSize: canvas)
                model.viewport.zoom = 1
                model.centerOnPixel(point, canvasSize: canvas)
            } else {
                model.fitToWindow(canvasSize: canvas)
            }
        }
    }

    private func hover(_ location: CGPoint?, canvas: CGSize) {
        guard let size = model.imageSize, let location else { probe = nil; return }
        let point = model.screenToImage(location, imgSize: size, canvasSize: canvas)
        guard point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else { probe = nil; return }
        model.updateCursorInfo(at: point)
        probe = location
    }
}

/// The pixels under the finger, magnified eight times beyond the view, with
/// the value and sky position; a light tick for each pixel crossed.
struct iOSLoupe: View {
    var model: FITSViewerModel
    let image: CGImage
    let size: CGSize
    let point: CGPoint

    private static let diameter: CGFloat = 132

    private var magnification: Double { max(8, model.viewport.zoom * 8) }
    private var pixel: (x: Int, y: Int) { (Int(point.x.rounded(.down)), Int(point.y.rounded(.down))) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.black
                let transform = ViewportTransform(zoom: magnification, rotation: model.viewport.rotation,
                                                  flipX: model.viewport.flipX, panX: 0, panY: 0, imageSize: size,
                                                  canvasSize: CGSize(width: Self.diameter, height: Self.diameter))
                let pan = transform.panToCenter(point)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size.width * magnification, height: size.height * magnification)
                    .scaleEffect(x: model.viewport.flipX ? -1 : 1, y: 1)
                    .rotationEffect(.radians(model.viewport.rotation))
                    .position(x: Self.diameter / 2 + pan.panX, y: Self.diameter / 2 + pan.panY)
                Rectangle()
                    .stroke(Color.green, lineWidth: 1.5)
                    .frame(width: magnification, height: magnification)
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
            .shadow(radius: 6)

            Text(verbatim: readout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.65), in: Capsule())
        }
        .sensoryFeedback(.selection, trigger: pixel.x &* 100_003 &+ pixel.y)
    }

    private var readout: String {
        let value = model.pixelValueText(atDisplay: point) ?? "—"
        guard let wcs = model.wcs, let height = model.imageSize?.height else { return value }
        let (ra, dec) = wcs.pixelToWorld(x: point.x, y: FITSViewerModel.displayToFITSY(point.y, naxis2: Int(height)))
        return "\(value) · \(Sexagesimal.readoutHMS(degrees: ra)) \(Sexagesimal.readoutDMS(degrees: dec))"
    }
}

/// North and East on the image, from its WCS: wherever the view is turned or
/// flipped, the arrows say where they are.
struct iOSCompassRose: View {
    var model: FITSViewerModel
    let size: CGSize
    let canvas: CGSize

    var body: some View {
        if let (north, east) = directions {
            ZStack {
                arrow(north, label: "N")
                arrow(east, label: "E")
            }
            .frame(width: 64, height: 64)
            .background(.black.opacity(0.35), in: Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Compass"))
        }
    }

    /// Unit vectors on screen toward North and East, from the image's centre.
    private var directions: (CGVector, CGVector)? {
        guard let wcs = model.wcs else { return nil }
        let height = Int(size.height)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let (ra, dec) = wcs.pixelToWorld(x: centre.x, y: FITSViewerModel.displayToFITSY(centre.y, naxis2: height))
        let step = max(wcs.pixelScaleArcsec, 0.01) * 20 / 3600
        func screenVector(ra: Double, dec: Double) -> CGVector? {
            guard let pixel = wcs.worldToPixel(ra: ra, dec: dec) else { return nil }
            let display = CGPoint(x: pixel.x, y: FITSViewerModel.displayToFITSY(pixel.y, naxis2: height))
            let from = model.imageToScreen(centre, imgSize: size, canvasSize: canvas)
            let to = model.imageToScreen(display, imgSize: size, canvasSize: canvas)
            let dx = to.x - from.x, dy = to.y - from.y, length = (dx * dx + dy * dy).squareRoot()
            return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : nil
        }
        guard let north = screenVector(ra: ra, dec: min(90, dec + step)),
              let east = screenVector(ra: ra + step / max(cos(dec * .pi / 180), 0.01), dec: dec) else { return nil }
        return (north, east)
    }

    private func arrow(_ direction: CGVector, label: String) -> some View {
        let length: CGFloat = 22
        let tip = CGPoint(x: 32 + direction.dx * length, y: 32 + direction.dy * length)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: 32, y: 32))
                path.addLine(to: tip)
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            Text(verbatim: label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .position(x: 32 + direction.dx * (length + 8), y: 32 + direction.dy * (length + 8))
        }
    }
}

/// A length on the sky at the view's zoom: a round number of seconds,
/// minutes or degrees, 60 to 140 points long.
struct iOSScaleBar: View {
    var model: FITSViewerModel

    private static let lengths: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 18000, 36000]

    var body: some View {
        if let wcs = model.wcs, wcs.pixelScaleArcsec > 0 {
            let pointsPerArcsec = model.viewport.zoom / wcs.pixelScaleArcsec
            let arcsec = Self.lengths.first { $0 * pointsPerArcsec >= 60 } ?? Self.lengths.last!
            let width = arcsec * pointsPerArcsec
            if width <= 160 {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Self.label(arcsec))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Rectangle()
                        .fill(.white)
                        .frame(width: width, height: 2)
                }
                .padding(6)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Self.label(arcsec)))
            }
        }
    }

    static func label(_ arcsec: Double) -> String {
        if arcsec >= 3600 { return "\((arcsec / 3600).formatted())°" }
        if arcsec >= 60 { return "\((arcsec / 60).formatted())′" }
        return "\(arcsec.formatted())″"
    }
}
