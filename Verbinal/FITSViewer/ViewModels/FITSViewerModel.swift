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

/// Per-file FITS viewer state.
@Observable
@MainActor
final class FITSViewerModel: Identifiable {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "FITSViewer")
    let id = UUID()
    var file: FITSFile?
    var selectedHDUIndex = 0
    var renderParams = FITSRenderParams()
    var viewport = FITSViewport()
    var renderedImage: CGImage?
    var pixels: [Float] = [] { didSet { updatePixelRange() } }

    /// Cached min/max of finite pixel values (for slider range).
    var pixelMin: Float = 0
    var pixelMax: Float = 1

    // Crosshair
    var crosshairPixel: CGPoint?
    var crosshairRA: String = ""
    var crosshairDec: String = ""
    var crosshairValue: String = ""
    /// True when the crosshair was applied from the linked-tab store, false when user-placed.
    var isLinkedCrosshair: Bool = false

    // Mouse readout
    var cursorRA: String = ""
    var cursorDec: String = ""
    var cursorPixelValue: String = ""

    // State
    var isLoading = false
    var loadError: String?
    var fileURL: URL?
    var lastCanvasSize: CGSize = CGSize(width: 800, height: 600)

    var selectedHDU: FITSHDUnit? {
        guard let file, selectedHDUIndex < file.hdus.count else { return nil }
        return file.hdus[selectedHDUIndex]
    }

    var imageHDUs: [FITSHDUnit] {
        file?.hdus.filter(\.isImage) ?? []
    }

    var wcs: FITSWCSTransform? { selectedHDU?.wcs }

    // MARK: - File Operations

    func open(url: URL) async {
        Self.logger.info("Opening FITS file: \(url.lastPathComponent, privacy: .public)")
        isLoading = true
        loadError = nil
        fileURL = url

        do {
            let (fitsFile, extractedPixels, cuts) = try await Task.detached {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let fitsFile = try FITSParser.parse(from: data)
                guard let imageHDU = fitsFile.firstImageHDU else {
                    throw FITSError.noImageHDU
                }
                let pixels = try FITSParser.extractPixels(from: data, hdu: imageHDU)
                let cuts = FITSParser.autoCut(pixels: pixels)
                return (fitsFile, pixels, cuts)
            }.value

            file = fitsFile
            selectedHDUIndex = fitsFile.firstImageHDU!.id
            pixels = extractedPixels
            renderParams.minCut = cuts.min
            renderParams.maxCut = cuts.max
            Self.logger.info("Loaded \(extractedPixels.count) pixels, cuts=[\(cuts.min), \(cuts.max)], HDUs=\(fitsFile.hdus.count), WCS=\(fitsFile.firstImageHDU?.wcs != nil)")

            await renderImageAsync()
            fitToWindow(canvasSize: lastCanvasSize)
        } catch {
            Self.logger.error("Failed to open FITS: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    func selectHDU(_ index: Int) async {
        guard let file, index < file.hdus.count, file.hdus[index].isImage else { return }
        selectedHDUIndex = index

        guard let url = fileURL else { return }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            pixels = try FITSParser.extractPixels(from: data, hdu: file.hdus[index])
            let cuts = FITSParser.autoCut(pixels: pixels)
            renderParams.minCut = cuts.min
            renderParams.maxCut = cuts.max
            renderImage()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Rendering

    func renderImage() {
        guard let hdu = selectedHDU, !pixels.isEmpty else { return }
        // Run rendering off main thread to avoid UI freeze
        Task { await renderImageAsync() }
    }

    private func renderImageAsync() async {
        guard let hdu = selectedHDU, !pixels.isEmpty else { return }
        let px = pixels
        let w = hdu.header.naxis1
        let h = hdu.header.naxis2
        let params = renderParams
        let image = await Task.detached {
            FITSRenderEngine.render(pixels: px, width: w, height: h, params: params)
        }.value
        renderedImage = image
    }

    // MARK: - Crosshair

    /// Callback for linked crosshair — set by tab host.
    var onCrosshairPlaced: ((Double, Double) -> Void)?
    /// Callback for linked zoom — set by tab host.
    var onZoomChanged: (() -> Void)?
    /// Callback for "Search at Position" context menu.
    var onSearchAtPosition: ((Double, Double) -> Void)?

    /// Apply a linked crosshair from the shared store (marks crosshair as linked).
    /// FITSTabHostModel should call this instead of setting crosshairPixel directly.
    func applyLinkedCrosshair(pixel: CGPoint, ra: Double, dec: Double) {
        crosshairPixel = pixel
        crosshairRA = FITSWCSTransform.formatRA(ra)
        crosshairDec = FITSWCSTransform.formatDec(dec)
        isLinkedCrosshair = true
    }

    /// Place crosshair at image pixel (0-based, display-space Y already flipped).
    func placeCrosshair(at point: CGPoint) {
        guard let hdu = selectedHDU else {
            Self.logger.warning("placeCrosshair: no selected HDU")
            return
        }
        Self.logger.debug("placeCrosshair at (\(point.x), \(point.y))")
        crosshairPixel = point
        isLinkedCrosshair = false

        let pixelIdx = Int(point.y) * hdu.header.naxis1 + Int(point.x)
        if pixelIdx >= 0 && pixelIdx < pixels.count {
            crosshairValue = String(format: "%.4g", pixels[pixelIdx])
        }

        if let wcs {
            let fitsY = Double(hdu.header.naxis2 - 1) - point.y
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            crosshairRA = FITSWCSTransform.formatRA(ra)
            crosshairDec = FITSWCSTransform.formatDec(dec)
            onCrosshairPlaced?(ra, dec)
        }
    }

    /// Update cursor readout (no permanent crosshair).
    func updateCursorInfo(at point: CGPoint) {
        guard let hdu = selectedHDU else { return }
        let pixelIdx = Int(point.y) * hdu.header.naxis1 + Int(point.x)
        if pixelIdx >= 0 && pixelIdx < pixels.count {
            cursorPixelValue = String(format: "%.4g", pixels[pixelIdx])
        }

        if let wcs {
            let fitsY = Double(hdu.header.naxis2 - 1) - point.y
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            cursorRA = FITSWCSTransform.formatRA(ra)
            cursorDec = FITSWCSTransform.formatDec(dec)
        }
    }

    // MARK: - Viewport

    func applyNorthUp() {
        guard let wcs else { return }
        viewport.rotation = -wcs.northAngle * .pi / 180.0
        viewport.flipX = wcs.hasParityFlip
    }

    func resetViewport() {
        viewport = FITSViewport()
    }

    /// Navigate viewport to center on a world coordinate (RA/Dec).
    func goToCoordinate(ra: Double, dec: Double) {
        guard let wcs, let hdu = selectedHDU else { return }
        guard let pixel = wcs.worldToPixel(ra: ra, dec: dec) else { return }
        let displayY = Double(hdu.header.naxis2 - 1) - pixel.y
        let imgPoint = CGPoint(x: pixel.x, y: displayY)
        placeCrosshair(at: imgPoint)
        centerOnPixel(imgPoint, canvasSize: lastCanvasSize)
    }

    /// Set zoom from UI controls. Centers on crosshair if placed (matches Windows SetZoomLevel).
    func setZoom(_ level: Double) {
        let clamped = max(0.05, min(20, level))
        viewport.zoom = clamped
        if let crosshair = crosshairPixel {
            centerOnPixel(crosshair, canvasSize: lastCanvasSize)
            Self.logger.debug("setZoom(\(level)): crosshair=(\(crosshair.x), \(crosshair.y)), canvas=\(self.lastCanvasSize.width)×\(self.lastCanvasSize.height), pan=(\(self.viewport.panX), \(self.viewport.panY))")
        }
        onZoomChanged?()
    }

    // MARK: - Coordinate Transforms (rotation-aware, matches Windows ViewportMath)

    /// Convert image pixel coordinates to screen coordinates.
    ///
    /// Applies: center → scale → flip → rotate → translate, matching
    /// Windows `ViewportMath.LocalToScreen`.
    ///
    /// - Parameters:
    ///   - imgPoint: Pixel position in image space (0-based, origin top-left).
    ///   - imgSize: Full pixel dimensions of the image.
    ///   - canvasSize: Size of the rendering canvas in screen points.
    /// - Returns: Position in screen/canvas coordinates.
    func imageToScreen(_ imgPoint: CGPoint, imgSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let zoom = viewport.zoom
        let rotation = viewport.rotation

        // Offset from image center, scaled
        var dx = (imgPoint.x - imgSize.width / 2) * zoom
        let dy = (imgPoint.y - imgSize.height / 2) * zoom

        // Apply horizontal flip before rotation (mirrors the .scaleEffect on the Image)
        if viewport.flipX { dx = -dx }

        // Apply rotation
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let rx = dx * cosR - dy * sinR
        let ry = dx * sinR + dy * cosR

        // Offset to canvas center + pan
        return CGPoint(
            x: canvasSize.width / 2 + viewport.panX + rx,
            y: canvasSize.height / 2 + viewport.panY + ry
        )
    }

    /// Convert screen coordinates to image pixel coordinates.
    ///
    /// Inverse of `imageToScreen`: un-translate → un-rotate → un-flip →
    /// un-scale → un-center.
    ///
    /// - Parameters:
    ///   - screenPoint: Position in screen/canvas coordinates.
    ///   - imgSize: Full pixel dimensions of the image.
    ///   - canvasSize: Size of the rendering canvas in screen points.
    /// - Returns: Pixel position in image space.
    func screenToImage(_ screenPoint: CGPoint, imgSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let zoom = viewport.zoom
        let rotation = viewport.rotation

        // Relative to canvas center + pan
        let relX = screenPoint.x - canvasSize.width / 2 - viewport.panX
        let relY = screenPoint.y - canvasSize.height / 2 - viewport.panY

        // Inverse rotation
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)
        var ux = relX * cosR - relY * sinR
        let uy = relX * sinR + relY * cosR

        // Undo horizontal flip (inverse of the .scaleEffect on the Image)
        if viewport.flipX { ux = -ux }

        // Un-scale and offset back to image center
        return CGPoint(
            x: ux / zoom + imgSize.width / 2,
            y: uy / zoom + imgSize.height / 2
        )
    }

    /// Center viewport on an image pixel, accounting for flip and rotation.
    func centerOnPixel(_ imgPoint: CGPoint, canvasSize: CGSize) {
        guard let hdu = selectedHDU else { return }
        let imgW = Double(hdu.header.naxis1)
        let imgH = Double(hdu.header.naxis2)

        // Offset from image center, scaled
        var dx = (imgPoint.x - imgW / 2) * viewport.zoom
        let dy = (imgPoint.y - imgH / 2) * viewport.zoom

        // Apply horizontal flip before rotation (mirrors imageToScreen)
        if viewport.flipX { dx = -dx }

        // Apply rotation to get screen-space offset
        let cosR = cos(viewport.rotation)
        let sinR = sin(viewport.rotation)
        let rx = dx * cosR - dy * sinR
        let ry = dx * sinR + dy * cosR

        // Pan so this point is at canvas center
        viewport.panX = -rx
        viewport.panY = -ry
    }

    /// Fit image to canvas size by computing the right zoom level.
    func fitToWindow(canvasSize: CGSize) {
        guard let hdu = selectedHDU else {
            resetViewport()
            return
        }
        let imgW = CGFloat(hdu.header.naxis1)
        let imgH = CGFloat(hdu.header.naxis2)
        guard imgW > 0, imgH > 0 else { return }
        let zoomX = canvasSize.width / imgW
        let zoomY = canvasSize.height / imgH
        viewport.zoom = min(zoomX, zoomY) * 0.95 // 5% margin
        viewport.rotation = 0
        if let crosshair = crosshairPixel {
            centerOnPixel(crosshair, canvasSize: canvasSize)
        } else {
            viewport.panX = 0
            viewport.panY = 0
        }
    }

    private func updatePixelRange() {
        guard !pixels.isEmpty else { pixelMin = 0; pixelMax = 1; return }
        var lo: Float = .greatestFiniteMagnitude
        var hi: Float = -.greatestFiniteMagnitude
        for p in pixels where p.isFinite {
            if p < lo { lo = p }
            if p > hi { hi = p }
        }
        pixelMin = lo < hi ? lo : 0
        pixelMax = lo < hi ? hi : 1
    }

    #if os(macOS)
    func openWithPicker() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.title = "Open FITS File"
        // Filter in panel message since UTI for FITS doesn't exist natively
        panel.message = "Select a FITS file (.fits, .fit, .fts)"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        await open(url: url)
    }
    #endif
}
