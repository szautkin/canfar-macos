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
    /// Raw WCS coordinates in decimal degrees (nil when no WCS or no crosshair).
    var crosshairRADeg: Double?
    var crosshairDecDeg: Double?
    /// True when the crosshair was applied from the linked-tab store, false when user-placed.
    var isLinkedCrosshair: Bool = false
    /// True when a linked crosshair coordinate is outside this image's bounds.
    var crosshairOutOfBounds: Bool = false
    /// RA/Dec strings for the out-of-bounds linked position (shown in sidebar).
    var outOfBoundsRA: String = ""
    var outOfBoundsDec: String = ""
    /// Pending toast message for the view layer to display. Consumed once shown.
    var pendingToast: String?

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
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= FITSViewerConstants.maxFileSize else {
                    throw FITSError.invalidFile("File too large: \(fileSize) bytes exceeds 4 GB limit")
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let fitsFile = try FITSParser.parse(from: data)
                guard let imageHDU = fitsFile.firstImageHDU else {
                    throw FITSError.noImageHDU
                }
                let pixels = try FITSParser.extractPixels(from: data, hdu: imageHDU)
                let cuts = FITSParser.autoCut(pixels: pixels)
                return (fitsFile, pixels, cuts)
            }.value

            guard let firstImageHDU = fitsFile.firstImageHDU else {
                throw FITSError.noImageHDU
            }
            file = fitsFile
            selectedHDUIndex = firstImageHDU.id
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
        let hdu = file.hdus[index]
        do {
            let (extractedPixels, cuts) = try await Task.detached {
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= FITSViewerConstants.maxFileSize else {
                    throw FITSError.invalidFile("File too large: \(fileSize) bytes exceeds 4 GB limit")
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let pixels = try FITSParser.extractPixels(from: data, hdu: hdu)
                let cuts = FITSParser.autoCut(pixels: pixels)
                return (pixels, cuts)
            }.value
            pixels = extractedPixels
            renderParams.minCut = cuts.min
            renderParams.maxCut = cuts.max
            renderImage()
        } catch {
            loadError = error.localizedDescription
        }

        // Issue 7: validate crosshair is still within the new HDU's bounds
        if let crosshair = crosshairPixel, let newHDU = selectedHDU {
            let naxis1 = Double(newHDU.header.naxis1)
            let naxis2 = Double(newHDU.header.naxis2)
            if crosshair.x < 0 || crosshair.x >= naxis1 ||
               crosshair.y < 0 || crosshair.y >= naxis2 {
                Self.logger.info("selectHDU: clearing crosshair out of new HDU bounds (\(crosshair.x), \(crosshair.y)) vs \(naxis1)×\(naxis2)")
                clearCrosshair()
            }
        }
    }

    // MARK: - Rendering

    /// Current render task — cancelled when a new render is requested.
    private var renderTask: Task<Void, Never>?
    /// Debounce task for slider-driven renders.
    private var renderDebounceTask: Task<Void, Never>?

    func renderImage() {
        guard selectedHDU != nil, !pixels.isEmpty else { return }
        renderTask?.cancel()
        renderTask = Task { await renderImageAsync() }
    }

    /// Debounced render — waits 80ms after last call before actually rendering.
    /// Use for slider drags to avoid 60 renders/sec.
    func renderImageDebounced() {
        renderDebounceTask?.cancel()
        renderDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(FITSViewerConstants.renderDebounceMs))
            guard !Task.isCancelled else { return }
            renderImage()
        }
    }

    /// True while an image render is in progress (drives the sidebar spinner).
    var isRendering = false

    private func renderImageAsync() async {
        guard let hdu = selectedHDU, !pixels.isEmpty else { return }
        isRendering = true
        let px = pixels
        let w = hdu.header.naxis1
        let h = hdu.header.naxis2
        let params = renderParams
        let image = await Task.detached {
            guard !Task.isCancelled else { return nil as CGImage? }
            let result = FITSRenderEngine.render(pixels: px, width: w, height: h, params: params)
            return Task.isCancelled ? nil : result  // Check INSIDE detached task
        }.value
        guard !Task.isCancelled, let image else {
            isRendering = false
            return
        }
        renderedImage = image
        isRendering = false
    }

    // MARK: - Crosshair

    /// Callback for linked crosshair (WCS) — set by tab host.
    var onCrosshairPlaced: (@MainActor (Double, Double) -> Void)?
    /// Callback for linked crosshair (pixel-only, no WCS) — set by tab host.
    var onPixelCrosshairPlaced: (@MainActor (CGPoint) -> Void)?
    /// Callback for linked zoom — set by tab host.
    var onZoomChanged: (@MainActor () -> Void)?
    /// Callback for "Search at Position" context menu.
    var onSearchAtPosition: (@MainActor (Double, Double) -> Void)?

    /// Clear the crosshair and all associated coordinate/value state.
    func clearCrosshair() {
        crosshairPixel = nil
        crosshairRA = ""
        crosshairDec = ""
        crosshairValue = ""
        crosshairRADeg = nil
        crosshairDecDeg = nil
        crosshairOutOfBounds = false
        outOfBoundsRA = ""
        outOfBoundsDec = ""
    }

    /// Dispatch a "search at crosshair" action if WCS coordinates are available.
    func searchAtCrosshair() {
        guard let ra = crosshairRADeg, let dec = crosshairDecDeg else { return }
        onSearchAtPosition?(ra, dec)
    }

    #if os(macOS)
    /// Copy the current crosshair RA/Dec to the system clipboard.
    func copyCoordsToClipboard() {
        let coords = "\(crosshairRA), \(crosshairDec)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(coords, forType: .string)
    }
    #endif

    // MARK: - Geometry Utilities

    /// Convert display Y (origin top-left) to FITS Y (origin bottom-left).
    static func displayToFITSY(_ displayY: Double, naxis2: Int) -> Double {
        Double(naxis2 - 1) - displayY
    }

    /// Compute linear pixel index from (x, y) position and image width.
    static func pixelIndex(x: Double, y: Double, width: Int) -> Int {
        Int(y) * width + Int(x)
    }

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
        guard point.x >= 0, point.y >= 0,
              point.x < Double(hdu.header.naxis1),
              point.y < Double(hdu.header.naxis2) else {
            Self.logger.warning("placeCrosshair: out of bounds (\(point.x), \(point.y)) for \(hdu.header.naxis1)×\(hdu.header.naxis2)")
            return
        }
        Self.logger.debug("placeCrosshair at (\(point.x), \(point.y))")
        crosshairPixel = point
        isLinkedCrosshair = false

        let pixelIdx = Self.pixelIndex(x: point.x, y: point.y, width: hdu.header.naxis1)
        if pixelIdx >= 0 && pixelIdx < pixels.count {
            let val = pixels[pixelIdx]
            crosshairValue = val.isFinite ? String(format: "%.4g", val) : "NaN"
        }

        // Clear out-of-bounds state when user places a new crosshair
        crosshairOutOfBounds = false

        if let wcs {
            let fitsY = Self.displayToFITSY(point.y, naxis2: hdu.header.naxis2)
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            crosshairRA = FITSWCSTransform.formatRA(ra)
            crosshairDec = FITSWCSTransform.formatDec(dec)
            crosshairRADeg = ra
            crosshairDecDeg = dec
            Self.logger.info("Crosshair WCS: RA=\(self.crosshairRA) Dec=\(self.crosshairDec) val=\(self.crosshairValue)")
            onCrosshairPlaced?(ra, dec)
        } else {
            Self.logger.info("placeCrosshair: no WCS — using pixel-only sync")
            crosshairRA = String(format: "px %.0f", point.x)
            crosshairDec = String(format: "py %.0f", point.y)
            crosshairRADeg = nil
            crosshairDecDeg = nil
            // Fire pixel-only sync callback for images without WCS
            onPixelCrosshairPlaced?(point)
        }
    }

    /// Update cursor readout (no permanent crosshair).
    func updateCursorInfo(at point: CGPoint) {
        guard let hdu = selectedHDU else { return }
        let pixelIdx = Self.pixelIndex(x: point.x, y: point.y, width: hdu.header.naxis1)
        if pixelIdx >= 0 && pixelIdx < pixels.count {
            let val = pixels[pixelIdx]
            cursorPixelValue = val.isFinite ? String(format: "%.4g", val) : "NaN"
        }

        if let wcs {
            let fitsY = Self.displayToFITSY(point.y, naxis2: hdu.header.naxis2)
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            cursorRA = FITSWCSTransform.formatRA(ra)
            cursorDec = FITSWCSTransform.formatDec(dec)
        }
    }

    // MARK: - Viewport

    func applyNorthUp() {
        guard let wcs else {
            Self.logger.warning("applyNorthUp: no WCS")
            return
        }
        viewport.rotation = -wcs.northAngle * .pi / 180.0
        viewport.flipX = wcs.hasParityFlip
        Self.logger.info("North Up: angle=\(wcs.northAngle)° rotation=\(self.viewport.rotation) flipX=\(self.viewport.flipX) pixelScale=\(wcs.pixelScaleArcsec)\"/px")
    }

    func resetViewport() {
        viewport = FITSViewport()
    }

    /// Navigate viewport to center on a world coordinate (RA/Dec).
    ///
    /// - Returns: `true` if the coordinate maps to a pixel within the image bounds,
    ///   `false` if the coordinate falls outside (crosshair is NOT placed).
    @discardableResult
    func goToCoordinate(ra: Double, dec: Double) -> Bool {
        guard let wcs, let hdu = selectedHDU else { return false }
        guard let pixel = wcs.worldToPixel(ra: ra, dec: dec) else { return false }

        let naxis1 = hdu.header.naxis1
        let naxis2 = hdu.header.naxis2
        guard pixel.x >= 0, pixel.x < Double(naxis1),
              pixel.y >= 0, pixel.y < Double(naxis2) else {
            Self.logger.info("goToCoordinate: (\(ra), \(dec)) → pixel (\(pixel.x), \(pixel.y)) outside \(naxis1)×\(naxis2)")
            return false
        }

        let displayY = Self.displayToFITSY(pixel.y, naxis2: naxis2)
        let imgPoint = CGPoint(x: pixel.x, y: displayY)
        placeCrosshair(at: imgPoint)
        centerOnPixel(imgPoint, canvasSize: lastCanvasSize)
        return true
    }

    /// Set zoom from UI controls. Centers on crosshair if placed (matches Windows SetZoomLevel).
    func setZoom(_ level: Double) {
        let clamped = max(FITSViewerConstants.zoomMin, min(FITSViewerConstants.zoomMax, level))
        viewport.zoom = clamped
        if let crosshair = crosshairPixel {
            centerOnPixel(crosshair, canvasSize: lastCanvasSize)
            Self.logger.info("setZoom(\(level)): pixel=(\(crosshair.x), \(crosshair.y)) RA=\(self.crosshairRA) Dec=\(self.crosshairDec) val=\(self.crosshairValue) zoom=\(self.viewport.zoom) pan=(\(self.viewport.panX), \(self.viewport.panY)) canvas=\(self.lastCanvasSize.width)×\(self.lastCanvasSize.height)")
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
        viewport.zoom = min(zoomX, zoomY) * FITSViewerConstants.fitMargin
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
        panel.title = String(localized: "Open FITS File")
        // Filter in panel message since UTI for FITS doesn't exist natively
        panel.message = String(localized: "Select a FITS file (.fits, .fit, .fts)")

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        await open(url: url)
    }
    #endif
}
