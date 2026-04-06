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

    var body: some View {
        GeometryReader { geometry in
            if let cgImage = model.renderedImage {
                let image = Image(decorative: cgImage, scale: 1)
                let imgWidth = CGFloat(cgImage.width)
                let imgHeight = CGFloat(cgImage.height)

                ZStack {
                    image
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
                    // Place crosshair at last known cursor position
                    if let hdu = model.selectedHDU {
                        // Use center of view as fallback
                        let cx = CGFloat(hdu.header.naxis1) / 2
                        let cy = CGFloat(hdu.header.naxis2) / 2
                        model.placeCrosshair(at: CGPoint(x: cx, y: cy))
                    }
                }
                .contextMenu {
                    Button("Reset View") { model.resetViewport() }
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
                                if let wcs = model.wcs, let pixel = model.crosshairPixel {
                                    let fitsY = Double(model.selectedHDU!.header.naxis2 - 1) - pixel.y
                                    let (ra, dec) = wcs.pixelToWorld(x: pixel.x, y: fitsY)
                                    // Dispatch to search via AppState (will be wired by parent)
                                    model.onSearchAtPosition?(ra, dec)
                                }
                            }
                        }
                    }
                }
                #endif
                .onScrollGesture { delta in
                    let zoomFactor = delta > 0 ? 1.1 : 0.9
                    model.viewport.zoom = max(0.1, min(20, model.viewport.zoom * zoomFactor))
                }
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
            // Horizontal line
            Rectangle()
                .fill(.red.opacity(0.7))
                .frame(width: 20, height: 1)
                .position(position)
            // Vertical line
            Rectangle()
                .fill(.red.opacity(0.7))
                .frame(width: 1, height: 20)
                .position(position)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Scroll Gesture (macOS)

private struct ScrollGestureModifier: ViewModifier {
    let action: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {} // placeholder — actual scroll handling via NSView event
    }
}

extension View {
    func onScrollGesture(action: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollGestureModifier(action: action))
    }
}
