// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// What the FITS viewer shows — the canvas with its zoom, pan, rotation,
/// flip, colormap and crosshair — as a picture, with the exact map from a
/// picture pixel back to the file's pixels. The viewport is affine, so six
/// numbers carry it: FITS 0-based array `x = a·u + b·v + c`,
/// `y = d·u + e·v + f`, for picture pixel (u, v) from the top-left.
struct FITSViewSnapshot {
    let image: CGImage
    let toFITS: (a: Double, b: Double, c: Double, d: Double, e: Double, f: Double)

    /// - Parameters:
    ///   - rendered: the viewer's rendered image (display rows: row 0 on top).
    ///   - viewport: the viewer's transform for its canvas.
    ///   - naxis2: rows in the file, to turn display rows into FITS rows.
    ///   - crosshair: the crosshair in display-image pixels, if placed.
    ///   - maxSide: the picture's longer side, at most.
    static func make(rendered: CGImage, viewport: ViewportTransform, naxis2: Int,
                     crosshair: CGPoint?, maxSide: Int) -> FITSViewSnapshot? {
        let canvas = viewport.canvasSize
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(canvas.width, canvas.height)))
        let width = max(1, Int((canvas.width * scale).rounded()))
        let height = max(1, Int((canvas.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Screen coordinates (y down), scaled to the picture.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        // The viewer's pipeline: centre → scale → flip → rotate → translate.
        context.saveGState()
        context.translateBy(x: canvas.width / 2 + viewport.panX, y: canvas.height / 2 + viewport.panY)
        context.rotate(by: viewport.rotation)
        context.scaleBy(x: viewport.flipX ? -viewport.zoom : viewport.zoom, y: viewport.zoom)
        context.translateBy(x: -viewport.imageSize.width / 2, y: -viewport.imageSize.height / 2)
        // CGContext draws an image bottom-up; flip it so row 0 is on top.
        context.translateBy(x: 0, y: viewport.imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(rendered, in: CGRect(origin: .zero, size: viewport.imageSize))
        context.restoreGState()

        if let crosshair {
            let at = viewport.imageToScreen(crosshair)
            context.setStrokeColor(CGColor(red: 0, green: 1, blue: 0.4, alpha: 0.9))
            context.setLineWidth(1.5 / CGFloat(scale))
            let arm = 12 / CGFloat(scale)
            context.strokeLineSegments(between: [CGPoint(x: at.x - arm, y: at.y), CGPoint(x: at.x + arm, y: at.y),
                                                 CGPoint(x: at.x, y: at.y - arm), CGPoint(x: at.x, y: at.y + arm)])
        }
        guard let image = context.makeImage() else { return nil }

        // Picture (u, v) → canvas (u/s, v/s) → display pixel → FITS row flip.
        func fits(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
            let display = viewport.screenToImage(CGPoint(x: u / scale, y: v / scale))
            return (display.x - 0.5, Double(naxis2) - display.y - 0.5)
        }
        let origin = fits(0, 0), right = fits(1, 0), down = fits(0, 1)
        return FITSViewSnapshot(image: image, toFITS: (
            a: right.x - origin.x, b: down.x - origin.x, c: origin.x,
            d: right.y - origin.y, e: down.y - origin.y, f: origin.y))
    }

    func fitsPixel(u: Double, v: Double) -> (x: Double, y: Double) {
        (toFITS.a * u + toFITS.b * v + toFITS.c, toFITS.d * u + toFITS.e * v + toFITS.f)
    }
}
