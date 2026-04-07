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
                            let zoomFactor = delta > 0 ? 1.1 : 0.9
                            let newZoom = max(0.05, min(20, oldZoom * zoomFactor))

                            let canvasCenter = CGSize(width: geometry.size.width / 2, height: geometry.size.height / 2)
                            let dx = mouseLocation.x - canvasCenter.width - model.viewport.panX
                            let dy = mouseLocation.y - canvasCenter.height - model.viewport.panY
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

    // MARK: - Coordinate Transforms

    private func imageToScreen(_ imgPoint: CGPoint, imgSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let zoom = model.viewport.zoom
        let centerX = canvasSize.width / 2 + model.viewport.panX
        let centerY = canvasSize.height / 2 + model.viewport.panY
        let x = centerX + (imgPoint.x - imgSize.width / 2) * zoom
        let y = centerY + (imgPoint.y - imgSize.height / 2) * zoom
        return CGPoint(x: x, y: y)
    }

    private func screenToImage(_ screenPoint: CGPoint, imgSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let zoom = model.viewport.zoom
        let centerX = canvasSize.width / 2 + model.viewport.panX
        let centerY = canvasSize.height / 2 + model.viewport.panY
        let x = (screenPoint.x - centerX) / zoom + imgSize.width / 2
        let y = (screenPoint.y - centerY) / zoom + imgSize.height / 2
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Crosshair Overlay

private struct CrosshairOverlay: View {
    let position: CGPoint

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.red.opacity(0.7))
                .frame(width: 20, height: 1)
                .position(position)
            Rectangle()
                .fill(.red.opacity(0.7))
                .frame(width: 1, height: 20)
                .position(position)
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
