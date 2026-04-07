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
struct FITSImageView: View {
    var model: FITSViewerModel

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
                        .rotationEffect(.radians(model.viewport.rotation))
                        .offset(x: model.viewport.panX, y: model.viewport.panY)

                    // Crosshair overlay
                    if let crosshair = model.crosshairPixel {
                        let screenPos = imageToScreen(crosshair, imgSize: imgSize, canvasSize: geometry.size)
                        CrosshairOverlay(position: screenPos)
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
                            let oldZoom = model.viewport.zoom
                            let zoomFactor = delta > 0 ? 1.15 : 1.0 / 1.15
                            let newZoom = max(0.05, min(20, oldZoom * zoomFactor))

                            // Zoom toward crosshair if placed, otherwise toward cursor (Windows behavior)
                            let anchor: CGPoint
                            if let crosshair = model.crosshairPixel {
                                anchor = imageToScreen(crosshair, imgSize: imgSize, canvasSize: geometry.size)
                            } else {
                                anchor = mouseLocation
                            }

                            let canvasCenter = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            let dx = anchor.x - canvasCenter.x - model.viewport.panX
                            let dy = anchor.y - canvasCenter.y - model.viewport.panY
                            let scale = 1 - newZoom / oldZoom
                            model.viewport.panX += dx * scale
                            model.viewport.panY += dy * scale
                            model.viewport.zoom = newZoom
                            model.onZoomChanged?()
                        },
                        onPan: { dx, dy in
                            model.viewport.panX += dx
                            model.viewport.panY += dy
                        },
                        onClick: { screenPoint in
                            let imgPoint = screenToImage(screenPoint, imgSize: imgSize, canvasSize: geometry.size)
                            Self.logger.debug("Click at screen=(\(screenPoint.x), \(screenPoint.y)) → image=(\(imgPoint.x), \(imgPoint.y))")
                            if imgPoint.x >= 0, imgPoint.y >= 0,
                               imgPoint.x < imgWidth, imgPoint.y < imgHeight {
                                model.placeCrosshair(at: imgPoint)
                                // Auto-center on crosshair when zoomed in (Windows behavior)
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
                            let imgPoint = screenToImage(screenPoint, imgSize: imgSize, canvasSize: geometry.size)
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

    // MARK: - Coordinate Transforms (rotation-aware, matches Windows ViewportMath)

    /// Convert image pixel coordinates to screen coordinates.
    /// Applies: center → scale → rotate → translate (matching Windows ViewportMath.LocalToScreen).
    private func imageToScreen(_ imgPoint: CGPoint, imgSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let zoom = model.viewport.zoom
        let rotation = model.viewport.rotation

        // Offset from image center, scaled
        let dx = (imgPoint.x - imgSize.width / 2) * zoom
        let dy = (imgPoint.y - imgSize.height / 2) * zoom

        // Apply rotation
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let rx = dx * cosR - dy * sinR
        let ry = dx * sinR + dy * cosR

        // Offset to canvas center + pan
        return CGPoint(
            x: canvasSize.width / 2 + model.viewport.panX + rx,
            y: canvasSize.height / 2 + model.viewport.panY + ry
        )
    }

    /// Convert screen coordinates to image pixel coordinates.
    /// Inverse of imageToScreen: un-translate → un-rotate → un-scale → un-center.
    private func screenToImage(_ screenPoint: CGPoint, imgSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let zoom = model.viewport.zoom
        let rotation = model.viewport.rotation

        // Relative to canvas center + pan
        let relX = screenPoint.x - canvasSize.width / 2 - model.viewport.panX
        let relY = screenPoint.y - canvasSize.height / 2 - model.viewport.panY

        // Inverse rotation
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)
        let ux = relX * cosR - relY * sinR
        let uy = relX * sinR + relY * cosR

        // Un-scale and offset back to image center
        return CGPoint(
            x: ux / zoom + imgSize.width / 2,
            y: uy / zoom + imgSize.height / 2
        )
    }
}

// MARK: - Crosshair Overlay

/// Full-canvas crosshair lines intersecting at the given position (matches Windows).
private struct CrosshairOverlay: View {
    let position: CGPoint

    var body: some View {
        Canvas { context, size in
            // Horizontal line
            var hPath = Path()
            hPath.move(to: CGPoint(x: 0, y: position.y))
            hPath.addLine(to: CGPoint(x: size.width, y: position.y))
            context.stroke(hPath, with: .color(.red.opacity(0.7)), lineWidth: 1)

            // Vertical line
            var vPath = Path()
            vPath.move(to: CGPoint(x: position.x, y: 0))
            vPath.addLine(to: CGPoint(x: position.x, y: size.height))
            context.stroke(vPath, with: .color(.red.opacity(0.7)), lineWidth: 1)
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

        if event.modifierFlags.contains(.shift) {
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            if abs(dx) > 0.1 { onPan?(dx, 0) }
            return
        }

        let delta = event.scrollingDeltaY
        if abs(delta) > 0.1 { onScroll?(delta, location) }
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

    override var acceptsFirstResponder: Bool { true }

    private func flippedLocation(for event: NSEvent) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)
        return CGPoint(x: loc.x, y: bounds.height - loc.y)
    }
}
#endif
