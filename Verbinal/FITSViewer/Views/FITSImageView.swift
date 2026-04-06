// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Displays the rendered FITS image with zoom, pan, and crosshair interaction.
struct FITSImageView: View {
    var model: FITSViewerModel

    @State private var dragStart: CGPoint?
    @State private var lastHoverPoint: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            if let cgImage = model.renderedImage {
                let imgWidth = CGFloat(cgImage.width)
                let imgHeight = CGFloat(cgImage.height)

                ZStack {
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
                        let screenPos = imageToScreen(
                            crosshair,
                            imgSize: CGSize(width: imgWidth, height: imgHeight),
                            canvasSize: geometry.size
                        )
                        CrosshairOverlay(position: screenPos)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        lastHoverPoint = location
                        let imgPoint = screenToImage(
                            location,
                            imgSize: CGSize(width: imgWidth, height: imgHeight),
                            canvasSize: geometry.size
                        )
                        if imgPoint.x >= 0, imgPoint.y >= 0,
                           imgPoint.x < imgWidth, imgPoint.y < imgHeight {
                            model.updateCursorInfo(at: imgPoint)
                        }
                    case .ended:
                        break
                    }
                }
                #if os(macOS)
                .onTapGesture(count: 1) {
                    // Place crosshair at last hover position (converted to image coords)
                    if let hover = lastHoverPoint {
                        let imgPoint = screenToImage(
                            hover,
                            imgSize: CGSize(width: imgWidth, height: imgHeight),
                            canvasSize: geometry.size
                        )
                        if imgPoint.x >= 0, imgPoint.y >= 0,
                           imgPoint.x < imgWidth, imgPoint.y < imgHeight {
                            model.placeCrosshair(at: imgPoint)
                        }
                    }
                }
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
                    ScrollCaptureView { delta, mouseLocation in
                        let oldZoom = model.viewport.zoom
                        let zoomFactor = delta > 0 ? 1.1 : 0.9
                        let newZoom = max(0.05, min(20, oldZoom * zoomFactor))

                        // Zoom toward cursor: adjust pan so the pixel under cursor stays fixed
                        let canvasCenter = CGSize(width: geometry.size.width / 2, height: geometry.size.height / 2)
                        let dx = mouseLocation.x - canvasCenter.width - model.viewport.panX
                        let dy = mouseLocation.y - canvasCenter.height - model.viewport.panY
                        let scale = 1 - newZoom / oldZoom
                        model.viewport.panX += dx * scale
                        model.viewport.panY += dy * scale
                        model.viewport.zoom = newZoom
                        model.onZoomChanged?()
                    }
                }
                #endif
            }
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                model.viewport.panX += value.translation.width - (dragStart?.x ?? 0)
                model.viewport.panY += value.translation.height - (dragStart?.y ?? 0)
                dragStart = CGPoint(x: value.translation.width, y: value.translation.height)
            }
            .onEnded { _ in
                dragStart = nil
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

/// Invisible NSView that captures scroll wheel events with mouse location.
struct ScrollCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

class ScrollCaptureNSView: NSView {
    var onScroll: ((CGFloat, CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if abs(delta) > 0.1 {
            let location = convert(event.locationInWindow, from: nil)
            let flipped = CGPoint(x: location.x, y: bounds.height - location.y)
            onScroll?(delta, flipped)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
#endif
