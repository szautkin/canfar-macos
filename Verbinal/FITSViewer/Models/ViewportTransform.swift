// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// Pure value type that captures everything needed to map between FITS
/// pixel coordinates and screen coordinates: the current viewport state
/// (zoom / flip / rotation / pan), the image's pixel dimensions, and the
/// canvas size in screen points.
///
/// Extracted from `FITSViewerModel` so the trig math is independently
/// testable and free of actor isolation. The model is `@MainActor`-bound
/// for I/O and rendering orchestration; coordinate transforms have no
/// such constraints, so isolating them here lets us unit-test them
/// directly without spinning up an entire view-model.
///
/// Convention matches Windows `ViewportMath.LocalToScreen` so the macOS
/// and Windows clients agree on crosshair / WCS positions to the pixel.
struct ViewportTransform: Sendable, Equatable {
    let zoom: Double
    let rotation: Double      // radians
    let flipX: Bool
    let panX: Double
    let panY: Double
    let imageSize: CGSize
    let canvasSize: CGSize

    /// Image pixel → screen point.
    /// Pipeline: center → scale → flip → rotate → translate.
    func imageToScreen(_ imgPoint: CGPoint) -> CGPoint {
        var dx = (imgPoint.x - imageSize.width / 2) * zoom
        let dy = (imgPoint.y - imageSize.height / 2) * zoom
        if flipX { dx = -dx }

        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let rx = dx * cosR - dy * sinR
        let ry = dx * sinR + dy * cosR

        return CGPoint(
            x: canvasSize.width / 2 + panX + rx,
            y: canvasSize.height / 2 + panY + ry
        )
    }

    /// Screen point → image pixel. Inverse of `imageToScreen(_:)`.
    func screenToImage(_ screenPoint: CGPoint) -> CGPoint {
        let relX = screenPoint.x - canvasSize.width / 2 - panX
        let relY = screenPoint.y - canvasSize.height / 2 - panY

        let cosR = cos(-rotation)
        let sinR = sin(-rotation)
        var ux = relX * cosR - relY * sinR
        let uy = relX * sinR + relY * cosR
        if flipX { ux = -ux }

        return CGPoint(
            x: ux / zoom + imageSize.width / 2,
            y: uy / zoom + imageSize.height / 2
        )
    }

    /// Compute the `(panX, panY)` that places `imgPoint` at the canvas
    /// centre. Caller is responsible for applying the pan back to viewport.
    func panToCenter(_ imgPoint: CGPoint) -> (panX: Double, panY: Double) {
        var dx = (imgPoint.x - imageSize.width / 2) * zoom
        let dy = (imgPoint.y - imageSize.height / 2) * zoom
        if flipX { dx = -dx }

        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let rx = dx * cosR - dy * sinR
        let ry = dx * sinR + dy * cosR
        return (-rx, -ry)
    }

    /// Zoom level that fits `imageSize` into `canvasSize`. Returns nil if
    /// either dimension is non-positive (caller should reset viewport).
    static func fitZoom(imageSize: CGSize, canvasSize: CGSize) -> Double? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let zoomX = canvasSize.width / imageSize.width
        let zoomY = canvasSize.height / imageSize.height
        return min(zoomX, zoomY)
    }
}
