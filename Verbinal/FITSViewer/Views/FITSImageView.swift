// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import os.log

/// Displays the rendered FITS image with zoom, pan, and crosshair interaction.
///
/// All mouse interaction is handled by ScrollCaptureNSView (NSView subclass)
/// to avoid SwiftUI gesture conflicts between tap and drag.
///
/// When `tabHost` is provided and a blink session is active, a second image layer
/// is rendered on top of the primary image using the WCS-aligned `BlinkTransform`.
/// The overlay opacity is driven by `tabHost.blinkOpacity`.
struct FITSImageView: View {
    var model: FITSViewerModel
    /// Optional tab host for blink overlay state. Nil in single-tab contexts.
    var tabHost: FITSTabHostModel?

    @Environment(\.fitsToast) private var toast

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "FITSImageView")

    var body: some View {
        GeometryReader { geometry in
            if let cgImage = model.renderedImage {
                let imgWidth = CGFloat(cgImage.width)
                let imgHeight = CGFloat(cgImage.height)
                let imgSize = CGSize(width: imgWidth, height: imgHeight)

                ZStack {
                    Color.clear.onAppear { model.lastCanvasSize = geometry.size }
                        .onChange(of: geometry.size) { _, newSize in model.lastCanvasSize = newSize }
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(
                            width: imgWidth * model.viewport.zoom,
                            height: imgHeight * model.viewport.zoom
                        )
                        .scaleEffect(x: model.viewport.flipX ? -1 : 1, y: 1)
                        .rotationEffect(.radians(model.viewport.rotation))
                        .offset(x: model.viewport.panX, y: model.viewport.panY)

                    // Blink overlay (image B), rendered with WCS-aligned transform
                    blinkOverlay(imgSize: imgSize)

                    // Crosshair overlay
                    if let crosshair = model.crosshairPixel {
                        let screenPos = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: geometry.size)
                        CrosshairOverlay(position: screenPos, isLinked: model.isLinkedCrosshair)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                #if os(macOS)
                .contextMenu {
                    Button("Reset View") { model.fitToWindow(canvasSize: geometry.size) }
                    if model.crosshairPixel != nil {
                        Button("Clear Crosshair") {
                            model.crosshairPixel = nil
                            model.crosshairRA = ""
                            model.crosshairDec = ""
                            model.crosshairValue = ""
                        }
                    }
                    if model.wcs != nil {
                        Button("North Up") { model.applyNorthUp() }
                        Divider()
                        if !model.crosshairRA.isEmpty {
                            Button("Copy RA/Dec") {
                                let coords = "\(model.crosshairRA), \(model.crosshairDec)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(coords, forType: .string)
                                toast?.show("Coordinates copied")
                            }
                            Button("Search at Position") {
                                if let wcs = model.wcs, let pixel = model.crosshairPixel,
                                   let hdu = model.selectedHDU {
                                    let fitsY = Double(hdu.header.naxis2 - 1) - pixel.y
                                    let (ra, dec) = wcs.pixelToWorld(x: pixel.x, y: fitsY)
                                    model.onSearchAtPosition?(ra, dec)
                                }
                            }
                        }
                    }
                }
                .overlay {
                    ScrollCaptureView(
                        onScroll: { delta, mouseLocation in
                            let newZoom = max(0.05, min(20,
                                model.viewport.zoom * (delta > 0 ? 1.15 : 1.0 / 1.15)))

                            // Windows ComputeZoomTranslate pattern:
                            // 1. Pick anchor: crosshair screen pos if placed, else cursor
                            // 2. Find what image pixel is at that anchor (old zoom)
                            // 3. Set new zoom
                            // 4. Compute exact pan so that image pixel stays at anchor

                            let anchorScreen: CGPoint
                            if let crosshair = model.crosshairPixel {
                                anchorScreen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: geometry.size)
                            } else {
                                anchorScreen = mouseLocation
                            }

                            // Image pixel under anchor (old zoom still in effect)
                            let anchorImg = model.screenToImage(anchorScreen, imgSize: imgSize, canvasSize: geometry.size)

                            // Apply new zoom
                            model.viewport.zoom = newZoom

                            // Compute pan so anchorImg maps back to anchorScreen.
                            // Must replicate imageToScreen's flip + rotate logic.
                            let rot = model.viewport.rotation
                            var dx = (anchorImg.x - imgSize.width / 2) * newZoom
                            let dy = (anchorImg.y - imgSize.height / 2) * newZoom
                            if model.viewport.flipX { dx = -dx }
                            let cosR = cos(rot)
                            let sinR = sin(rot)
                            model.viewport.panX = anchorScreen.x - geometry.size.width / 2 - (dx * cosR - dy * sinR)
                            model.viewport.panY = anchorScreen.y - geometry.size.height / 2 - (dx * sinR + dy * cosR)

                            model.onZoomChanged?()
                        },
                        onPan: { dx, dy in
                            model.viewport.panX += dx
                            model.viewport.panY += dy
                        },
                        onClick: { screenPoint in
                            let imgPoint = model.screenToImage(screenPoint, imgSize: imgSize, canvasSize: geometry.size)
                            Self.logger.debug("Click at screen=(\(screenPoint.x), \(screenPoint.y)) → image=(\(imgPoint.x), \(imgPoint.y))")
                            if imgPoint.x >= 0, imgPoint.y >= 0,
                               imgPoint.x < imgWidth, imgPoint.y < imgHeight {
                                model.placeCrosshair(at: imgPoint)
                                if model.viewport.zoom > 1.05 {
                                    model.centerOnPixel(imgPoint, canvasSize: geometry.size)
                                }
                                Self.logger.info("Crosshair placed at (\(imgPoint.x), \(imgPoint.y))")
                            }
                        },
                        onDrag: { dx, dy in
                            model.viewport.panX += dx
                            model.viewport.panY += dy
                        },
                        onHover: { screenPoint in
                            let imgPoint = model.screenToImage(screenPoint, imgSize: imgSize, canvasSize: geometry.size)
                            if imgPoint.x >= 0, imgPoint.y >= 0,
                               imgPoint.x < imgWidth, imgPoint.y < imgHeight {
                                model.updateCursorInfo(at: imgPoint)
                            }
                        }
                    )
                }
                #endif
            }
        }
    }

    // MARK: - Blink Overlay

    /// Renders image B as an aligned overlay on top of image A.
    ///
    /// When WCS alignment is available (`blinkTransform` is set), the overlay is
    /// positioned using the computed `BlinkTransform` (North-up, matched angular scale,
    /// centered on the reference RA/Dec).
    ///
    /// When WCS is absent (no transform), the overlay tracks image A's zoom/pan —
    /// a best-effort unaligned blink, still useful for same-instrument images.
    @ViewBuilder
    private func blinkOverlay(imgSize: CGSize) -> some View {
        if let host = tabHost,
           host.isBlinking,
           let overlayImage = host.blinkOverlayImage
        {
            if let transform = host.blinkTransform {
                // WCS-aligned overlay using the computed BlinkTransform.
                //
                // The overlay fills image A's pixel dimensions (Stretch=Fill equivalent).
                // Transform order (center-origin CompositeTransform, matching Windows):
                //   1. frame() sets the image to A's pixel dimensions
                //   2. scaleEffect(x: ±1) mirrors for parity flip when scaleX < 0
                //   3. rotationEffect rotates around image center
                //   4. scaleEffect(abs) applies the zoom magnitude
                //   5. offset() applies the WCS-computed pan/translate
                Image(decorative: overlayImage, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: imgSize.width, height: imgSize.height)
                    .scaleEffect(
                        x: transform.scaleX < 0 ? -1 : 1,
                        y: 1,
                        anchor: .center
                    )
                    .rotationEffect(.radians(transform.rotation))
                    .scaleEffect(
                        x: abs(transform.scaleX),
                        y: transform.scaleY,
                        anchor: .center
                    )
                    .offset(x: transform.translateX, y: transform.translateY)
                    .opacity(host.blinkOpacity)
                    .allowsHitTesting(false)
            } else {
                // No WCS: unaligned overlay tracks image A's current zoom/pan.
                Image(decorative: overlayImage, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(
                        width: imgSize.width * model.viewport.zoom,
                        height: imgSize.height * model.viewport.zoom
                    )
                    .scaleEffect(x: model.viewport.flipX ? -1 : 1, y: 1)
                    .rotationEffect(.radians(model.viewport.rotation))
                    .offset(x: model.viewport.panX, y: model.viewport.panY)
                    .opacity(host.blinkOpacity)
                    .allowsHitTesting(false)
            }
        }
    }

}

// MARK: - Crosshair Overlay

/// Full-canvas crosshair lines intersecting at the given position (matches Windows).
/// - Primary (user-placed, isLinked=false): solid red lines at 0.7 opacity.
/// - Linked (from store, isLinked=true): dashed yellow lines at 0.7 opacity.
private struct CrosshairOverlay: View {
    let position: CGPoint
    let isLinked: Bool

    var body: some View {
        Canvas { context, size in
            // Horizontal line
            var hPath = Path()
            hPath.move(to: CGPoint(x: 0, y: position.y))
            hPath.addLine(to: CGPoint(x: size.width, y: position.y))

            // Vertical line
            var vPath = Path()
            vPath.move(to: CGPoint(x: position.x, y: 0))
            vPath.addLine(to: CGPoint(x: position.x, y: size.height))

            if isLinked {
                let style = StrokeStyle(lineWidth: 1, dash: [4, 4])
                context.stroke(hPath, with: .color(.yellow.opacity(0.7)), style: style)
                context.stroke(vPath, with: .color(.yellow.opacity(0.7)), style: style)
            } else {
                context.stroke(hPath, with: .color(.red.opacity(0.7)), lineWidth: 1)
                context.stroke(vPath, with: .color(.red.opacity(0.7)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - NSView Scroll Capture (macOS)

#if os(macOS)
import AppKit

/// Invisible NSView that captures scroll wheel, click, and drag events.
/// - Scroll: zoom toward cursor
/// - Shift+scroll: horizontal pan
/// - Click (no drag): place crosshair
/// - Drag: pan image
struct ScrollCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat, CGPoint) -> Void
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onHover: ((CGPoint) -> Void)?

    func makeNSView(context: Context) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView()
        view.onScroll = onScroll
        view.onPan = onPan
        view.onClick = onClick
        view.onDrag = onDrag
        view.onHover = onHover
        // Enable mouse tracking for hover
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: view)
        view.addTrackingArea(area)
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onPan = onPan
        nsView.onClick = onClick
        nsView.onDrag = onDrag
        nsView.onHover = onHover
    }
}

class ScrollCaptureNSView: NSView {
    var onScroll: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onHover: ((CGPoint) -> Void)?

    private var mouseDownLocation: CGPoint?
    private var didDrag = false
    private static let dragThreshold: CGFloat = 3.0

    override func scrollWheel(with event: NSEvent) {
        let location = flippedLocation(for: event)

        if event.modifierFlags.contains(.command) {
            // Cmd+scroll = zoom toward crosshair/cursor (matches Windows Ctrl+scroll)
            let delta = event.scrollingDeltaY
            if abs(delta) > 0.1 { onScroll?(delta, location) }
            return
        }

        if event.modifierFlags.contains(.shift) {
            // Shift+scroll = horizontal pan
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            if abs(dx) > 0.1 { onPan?(dx, 0) }
            return
        }

        // Bare scroll = vertical pan (matches Windows bare scroll)
        let dy = event.scrollingDeltaY
        if abs(dy) > 0.1 { onPan?(0, -dy) }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = flippedLocation(for: event)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let current = flippedLocation(for: event)
        let dx = current.x - start.x
        let dy = current.y - start.y
        if !didDrag && sqrt(dx * dx + dy * dy) < Self.dragThreshold { return }
        didDrag = true
        onDrag?(event.deltaX, -event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag, let loc = mouseDownLocation {
            onClick?(loc)
        }
        mouseDownLocation = nil
        didDrag = false
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(flippedLocation(for: event))
    }

    override func magnify(with event: NSEvent) {
        let location = flippedLocation(for: event)
        // magnification is a delta: positive = zoom in, negative = zoom out.
        // Scale to a delta comparable to Cmd+scroll for consistent zoom speed.
        let delta = event.magnification * 5.0
        if abs(delta) > 0.01 { onScroll?(delta, location) }
    }

    override var acceptsFirstResponder: Bool { true }

    private func flippedLocation(for event: NSEvent) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)
        return CGPoint(x: loc.x, y: bounds.height - loc.y)
    }
}
#endif
