// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import CoreGraphics
import os.log
#if os(macOS)
import AppKit
#endif
import VerbinalKit

/// Between the screen, the image's pixels and the sky (delegated to ViewportTransform).
extension FITSViewerModel {
    // MARK: - Coordinate Transforms (delegated to ViewportTransform)
    //
    // The trig math lives in `ViewportTransform` so it's testable without
    // spinning up the model. These shims package the current viewport +
    // image dimensions into a transform and call through.

    func makeTransform(imgSize: CGSize, canvasSize: CGSize) -> ViewportTransform {
        ViewportTransform(
            zoom: viewport.zoom,
            rotation: viewport.rotation,
            flipX: viewport.flipX,
            panX: viewport.panX,
            panY: viewport.panY,
            imageSize: imgSize,
            canvasSize: canvasSize
        )
    }

    /// The viewport over the image on a canvas; nil before a render. Sized
    /// by the image's pixels, not the picture's — they differ past
    /// `FITSDisplayRaster`'s limits, and coordinates are the image's.
    func displayTransform(canvasSize: CGSize) -> ViewportTransform? {
        guard renderedImage != nil, let size = imageSize else { return nil }
        return makeTransform(imgSize: size, canvasSize: canvasSize)
    }

    /// The selected image's size in its own pixels.
    var imageSize: CGSize? {
        selectedHDU.map { CGSize(width: $0.header.naxis1, height: $0.header.naxis2) }
    }

    /// Image pixel → screen point. See ``ViewportTransform/imageToScreen(_:)``.
    func imageToScreen(_ imgPoint: CGPoint, imgSize: CGSize, canvasSize: CGSize) -> CGPoint {
        makeTransform(imgSize: imgSize, canvasSize: canvasSize).imageToScreen(imgPoint)
    }

    /// Screen point → image pixel. See ``ViewportTransform/screenToImage(_:)``.
    func screenToImage(_ screenPoint: CGPoint, imgSize: CGSize, canvasSize: CGSize) -> CGPoint {
        makeTransform(imgSize: imgSize, canvasSize: canvasSize).screenToImage(screenPoint)
    }

    /// Center viewport on an image pixel, accounting for flip and rotation.
    func centerOnPixel(_ imgPoint: CGPoint, canvasSize: CGSize) {
        guard let hdu = selectedHDU else { return }
        let imgSize = CGSize(width: hdu.header.naxis1, height: hdu.header.naxis2)
        let pan = makeTransform(imgSize: imgSize, canvasSize: canvasSize).panToCenter(imgPoint)
        viewport.panX = pan.panX
        viewport.panY = pan.panY
    }

    /// Fit image to canvas size by computing the right zoom level.
    func fitToWindow(canvasSize: CGSize) {
        guard selectedHDU != nil else {
            resetViewport()
            return
        }
        viewport.rotation = 0
        fitZoomKeepingRotation(canvasSize: canvasSize)
    }

    /// The zoom that shows the whole image at the view's rotation, with the
    /// margin the viewer leaves.
    func fittedZoom(canvasSize: CGSize) -> Double? {
        guard let hdu = selectedHDU else { return nil }
        let imgSize = CGSize(width: hdu.header.naxis1, height: hdu.header.naxis2)
        return ViewportTransform.fitZoom(imageSize: imgSize, canvasSize: canvasSize, rotation: viewport.rotation)
            .map { $0 * FITSViewerConstants.fitMargin }
    }

    /// Whether the view shows the whole image as fitted, give or take 5%.
    func isFitted(canvasSize: CGSize) -> Bool {
        guard let fit = fittedZoom(canvasSize: canvasSize), fit > 0 else { return false }
        return abs(viewport.zoom - fit) / fit < 0.05
    }

    /// Fits the whole image, turned as it is, and centres it (on the crosshair when there is one).
    func fitZoomKeepingRotation(canvasSize: CGSize) {
        guard let fit = fittedZoom(canvasSize: canvasSize) else { return }
        viewport.zoom = fit
        if let crosshair = crosshairPixel {
            centerOnPixel(crosshair, canvasSize: canvasSize)
        } else {
            viewport.panX = 0
            viewport.panY = 0
        }
    }

    /// Single-pass min/max scan over the pixel buffer, finite-only.
    /// Static + non-isolated so callers can run it from `Task.detached` —
    /// the previous instance method lived on `@MainActor` and ran the loop
    /// every time `pixels` was assigned, blocking the UI on large images.
    nonisolated static func scanPixelRange(_ pixels: [Float]) -> (min: Float, max: Float, degenerate: Bool) {
        guard !pixels.isEmpty else {
            logger.warning("scanPixelRange: empty pixel buffer — falling back to degenerate 0...1 range")
            return (0, 1, true)
        }
        var lo: Float = .greatestFiniteMagnitude
        var hi: Float = -.greatestFiniteMagnitude
        for p in pixels where p.isFinite {
            if p < lo { lo = p }
            if p > hi { hi = p }
        }
        if lo < hi { return (lo, hi, false) }
        // Uniform (all-identical) or all-NaN data: no usable spread. Surface the
        // degenerate condition rather than masking it behind a silent fallback.
        logger.warning("scanPixelRange: degenerate pixel range (uniform or all-NaN data) — falling back to 0...1")
        return (0, 1, true)
    }

    #if os(macOS)
    func openWithPicker() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Open FITS File")
        // Filter in panel message since UTI for FITS doesn't exist natively
        panel.message = String(localized: "Select a FITS file (.fits, .fit, .fts)")

        let response = await UIPresentations.shared.runModal(panel, "Open FITS File")
        guard response == .OK, let url = panel.url else { return }
        await open(url: url)
    }
    #endif
}
