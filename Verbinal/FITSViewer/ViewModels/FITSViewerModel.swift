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

/// What the viewer draws of an image: at most `FITSDisplayRaster`'s limits.
struct FITSPicture: Sendable {
    let pixels: [Float]
    let width: Int
    let height: Int

    nonisolated init(pixels: [Float], width: Int, height: Int) {
        (self.pixels, self.width, self.height) = FITSDisplayRaster.picture(of: pixels, width: width, height: height)
    }
}

/// Per-file FITS viewer state.
@Observable
@MainActor
final class FITSViewerModel: Identifiable {
    private nonisolated static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "FITSViewer")
    let id = UUID()
    var file: FITSFile?
    var selectedHDUIndex = 0
    var renderParams = FITSRenderParams()
    var viewport = FITSViewport()
    var renderedImage: CGImage?
    /// Pixel data for the currently selected image HDU.
    ///
    /// Note: this is intentionally *not* a `didSet`-observed property. The
    /// previous design ran `updatePixelRange()` on every assignment from
    /// the `@MainActor`, which scans every pixel — multi-second pause for
    /// large images. The min/max scan now happens inside the detached load
    /// task and `pixelMin`/`pixelMax` are assigned alongside `pixels`.
    ///
    /// `@ObservationIgnored` on top: no view renders the buffer reactively
    /// (readers are event-driven — probe, auto-cut, render), and keeping a
    /// 400 MB array out of Observation's access tracking keeps its
    /// assignment from contributing main-actor work right when the MCP
    /// tools' `MainActor.run` hops are queued behind a big load (F5).
    @ObservationIgnored var pixels: [Float] = [] {
        didSet {
            picture = nil
            pixelsVersion += 1
        }
    }
    /// Counts changes of `pixels`, so a picture worked out for older ones is not kept.
    @ObservationIgnored private var pixelsVersion = 0
    /// What is drawn: `pixels` themselves, or their block average when the
    /// image is past what a screen or a Metal texture takes
    /// (`FITSDisplayRaster`); nil until worked out for these pixels. Values
    /// and coordinates are always read from `pixels` — this is for colouring in.
    @ObservationIgnored private var picture: FITSPicture?

    /// Cached min/max of finite pixel values (for slider range).
    var pixelMin: Float = 0
    var pixelMax: Float = 1

    /// True when the most recent pixel scan found no usable spread — an empty
    /// buffer, uniform (all-identical) pixels, or an all-NaN image. In that case
    /// `pixelMin`/`pixelMax` carry the 0...1 *fallback* rather than a real data
    /// range, so the cut-range slider can surface that to the astronomer instead
    /// of silently presenting a bogus 0...1 window.
    ///
    /// This must be a stored flag fed from the scan (see ``scanPixelRange(_:)``),
    /// not derived from `pixelMin >= pixelMax`: the fallback range is `0...1`,
    /// where `0 < 1`, so a min/max comparison can never distinguish a genuine
    /// 0...1 data range from the degenerate fallback.
    var pixelRangeDegenerate: Bool = false

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
    /// The Export Figure sheet is open on this region (a mark's menu opens
    /// it framed on the mark); nil when it is closed.
    var figureRegion: FITSFigureRegion?

    // Mouse readout
    var cursorRA: String = ""
    var cursorDec: String = ""
    var cursorPixelValue: String = ""

    // State
    var isLoading = false
    /// Where an open has got to — "Reading the pixels" — while `isLoading`.
    var loadStage = ""
    /// Files opened lately, for the empty screen.
    @ObservationIgnored var recentFiles = RecentFiles.fits
    var loadError: String?
    var fileURL: URL?
    /// What the selected HDU shows when it is a table — its spectrum, or
    /// its columns — rather than a picture of its rows (plan 17 U4, QA N1).
    var table: FITSTableContent?
    var lastCanvasSize: CGSize = CGSize(width: 800, height: 600)

    var selectedHDU: FITSHDUnit? {
        guard let file, selectedHDUIndex < file.hdus.count else { return nil }
        return file.hdus[selectedHDUIndex]
    }

    /// The HDUs a person can look at: images, and tables.
    var viewableHDUs: [FITSHDUnit] {
        file?.hdus.filter { $0.isImage || $0.isTable } ?? []
    }

    var wcs: FITSWCSTransform? { selectedHDU?.wcs }

    /// What the tab is called: its file's name.
    var displayName: String { fileURL?.lastPathComponent ?? String(localized: "Untitled") }

    // MARK: - File Operations

    func open(url: URL) async {
        Self.logger.info("Opening FITS file: \(url.lastPathComponent, privacy: .public)")
        isLoading = true
        loadError = nil
        fileURL = url

        // For files saved via NSSavePanel and resolved from a security-scoped
        // bookmark (Research downloads), the sandbox requires
        // start/stopAccessingSecurityScopedResource() around the read. The
        // call is a safe no-op for non-scoped URLs (NSOpenPanel-picked
        // files already have process-scoped grants), so we always pair it.
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }

        do {
            loadStage = String(localized: "Reading the header")
            let (data, fitsFile) = try await Task.detached {
                // Mapped, not read: the file's size is not what memory holds.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return (data, try FITSParser.parse(from: data))
            }.value
            guard let firstImageHDU = fitsFile.firstImageHDU else {
                // No image: a table's spectrum, or its columns (plan 17 U4).
                let first = await Task.detached { FITSTableContent.first(of: fitsFile, in: data) }.value
                guard let (hdu, content) = first else { throw FITSError.noImageHDU }
                file = fitsFile
                selectedHDUIndex = hdu.id
                showTable(content)
                recentFiles.add(url)
                isLoading = false
                return
            }
            loadStage = Self.readingStage(of: firstImageHDU)
            let image = try await Task.detached { try LoadedImage(data: data, hdu: firstImageHDU) }.value
            loadStage = String(localized: "Drawing")

            file = fitsFile
            selectedHDUIndex = firstImageHDU.id
            table = nil
            apply(image)
            Self.logger.info("Loaded \(image.pixels.count) pixels (drawn at \(image.picture.width)×\(image.picture.height)), HDUs=\(fitsFile.hdus.count), WCS=\(fitsFile.firstImageHDU?.wcs != nil)")

            await renderImageAsync()
            fitToWindow(canvasSize: lastCanvasSize)
            recentFiles.add(url)
        } catch {
            Self.logger.error("Failed to open FITS: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    func selectHDU(_ index: Int) async {
        guard let file, index < file.hdus.count, file.hdus[index].isImage || file.hdus[index].isTable else { return }
        selectedHDUIndex = index

        guard let url = fileURL else { return }
        let hdu = file.hdus[index]

        // Same scope discipline as `open(url:)` — the file may live in a
        // sandbox-restricted location that requires explicit access.
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }

        if hdu.isTable {
            do {
                let content = try await Task.detached {
                    FITSTableContent.read(hdu, in: try Data(contentsOf: url, options: .mappedIfSafe))
                }.value
                if let content { showTable(content) }
            } catch {
                loadError = error.localizedDescription
            }
            return
        }
        table = nil

        do {
            let image = try await Task.detached {
                try LoadedImage(data: Data(contentsOf: url, options: .mappedIfSafe), hdu: hdu)
            }.value
            apply(image)
            renderImage()
        } catch {
            loadError = error.localizedDescription
        }

        // Issue 7 / Ticket 010: reconcile the crosshair with the new HDU.
        if let newHDU = selectedHDU {
            reconcileCrosshair(naxis1: newHDU.header.naxis1, naxis2: newHDU.header.naxis2)
        }
    }

    /// An image's pixels as read, with what the view needs from them —
    /// found off the main actor, applied on it in one step.
    struct LoadedImage: Sendable {
        let pixels: [Float]
        let picture: FITSPicture
        let cuts: (min: Float, max: Float)
        let range: (min: Float, max: Float, degenerate: Bool)

        /// Reads `hdu`'s pixels from `data` — refused before any is read when
        /// the memory free cannot hold them (`FITSMemoryBudget`).
        nonisolated init(data: Data, hdu: FITSHDUnit) throws {
            pixels = try FITSParser.extractPixels(from: data, hdu: hdu)
            picture = FITSPicture(pixels: pixels, width: hdu.header.naxis1, height: hdu.header.naxis2)
            cuts = FITSParser.autoCut(pixels: pixels)
            range = FITSViewerModel.scanPixelRange(pixels)
        }
    }

    /// What reading an image's pixels is, for the loading screen: its size,
    /// and whether its tiles are being uncompressed.
    nonisolated static func readingStage(of hdu: FITSHDUnit) -> String {
        let size = "\(hdu.header.naxis1.formatted()) × \(hdu.header.naxis2.formatted())"
        return hdu.isCompressed
            ? String(localized: "Uncompressing \(size) pixels")
            : String(localized: "Reading \(size) pixels")
    }

    /// Shows a table instead of a picture.
    private func showTable(_ content: FITSTableContent) {
        table = content
        pixels = []
        renderedImage = nil
    }

    private func apply(_ image: LoadedImage) {
        pixels = image.pixels
        picture = image.picture  // after `pixels`, whose change clears it
        pixelMin = image.range.min
        pixelMax = image.range.max
        pixelRangeDegenerate = image.range.degenerate
        renderParams.minCut = image.cuts.min
        renderParams.maxCut = image.cuts.max
    }

    // MARK: - Rendering

    /// Current render task — cancelled when a new render is requested.
    private var renderTask: Task<Void, Never>?
    /// Debounce task for slider-driven renders.
    private var renderDebounceTask: Task<Void, Never>?

    /// Debounce delay used by `renderImageDebounced()`. Defaults to the shared
    /// constant; overridable so tests can exercise the debounce with a short
    /// interval without waiting the full slider delay.
    var renderDebounceMs: Int = FITSViewerConstants.renderDebounceMs

    /// Test seam: when set, the debounce fires this instead of `renderImage()`.
    /// Lets tests count fired renders without a loaded file/HDU (which
    /// `renderImage()` requires). Nil in production, so behavior is unchanged.
    var renderImageOverride: (@MainActor () -> Void)?

    func renderImage() {
        guard selectedHDU != nil, !pixels.isEmpty else { return }
        renderTask?.cancel()
        renderTask = Task { await renderImageAsync() }
    }

    /// Debounced render — waits `renderDebounceMs` after the last call before
    /// actually rendering. Use for slider drags to avoid 60 renders/sec.
    ///
    /// Each call cancels the previously scheduled debounce task, so the
    /// `Task.sleep` below is the deliberate cancellation point: a superseding
    /// call throws `CancellationError` out of the sleep, which we treat as
    /// "this debounce was replaced — do nothing." Any *other* error from the
    /// sleep is a scheduling anomaly we intentionally ignore; the post-catch
    /// `isCancelled` guard still short-circuits a cancelled task before we
    /// touch render state.
    func renderImageDebounced() {
        renderDebounceTask?.cancel()
        let delayMs = renderDebounceMs
        renderDebounceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch is CancellationError {
                return  // Superseded by a newer debounce — intentional.
            } catch {
                return  // Non-cancellation sleep failure — deliberately ignored.
            }
            guard !Task.isCancelled else { return }
            if let renderImageOverride {
                renderImageOverride()
            } else {
                renderImage()
            }
        }
    }

    /// Test seam: awaits completion of the in-flight debounce task (the one that
    /// either fired a render or returned after being superseded). Returns
    /// immediately when no debounce is scheduled.
    func awaitDebounceForTesting() async {
        await renderDebounceTask?.value
    }

    /// True while an image render is in progress (drives the sidebar spinner).
    var isRendering = false

    private func renderImageAsync() async {
        guard let hdu = selectedHDU, !pixels.isEmpty else { return }
        isRendering = true
        let known = picture
        let version = pixelsVersion
        let px = pixels
        let (w, h) = (hdu.header.naxis1, hdu.header.naxis2)
        let params = renderParams
        let (image, drawn) = await Task.detached {
            let drawn = known ?? FITSPicture(pixels: px, width: w, height: h)
            guard !Task.isCancelled else { return (nil as CGImage?, drawn) }
            let result = FITSRenderEngine.render(pixels: drawn.pixels, width: drawn.width, height: drawn.height, params: params)
            return (Task.isCancelled ? nil : result, drawn)  // Check INSIDE detached task
        }.value
        if picture == nil, version == pixelsVersion { picture = drawn }
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

    /// Reconcile the crosshair with a newly-selected HDU's bounds: clear it
    /// entirely if it now falls outside, or — when it's still valid (or
    /// absent) — clear any stale out-of-bounds RA/Dec readout left over from a
    /// prior linked operation so the sidebar never shows old out-of-bounds
    /// coordinates on a valid view. Extracted from `selectHDU` for testability.
    func reconcileCrosshair(naxis1: Int, naxis2: Int) {
        guard let crosshair = crosshairPixel else {
            clearStaleOutOfBounds()
            return
        }
        let w = Double(naxis1), h = Double(naxis2)
        if crosshair.x < 0 || crosshair.x >= w || crosshair.y < 0 || crosshair.y >= h {
            Self.logger.info("selectHDU: clearing crosshair out of new HDU bounds (\(crosshair.x), \(crosshair.y)) vs \(naxis1)×\(naxis2)")
            clearCrosshair()
        } else {
            clearStaleOutOfBounds()
        }
    }

    private func clearStaleOutOfBounds() {
        guard crosshairOutOfBounds else { return }
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
        PlatformClipboard.copy("\(crosshairRA), \(crosshairDec)")
    }
    #endif

    // MARK: - Geometry Utilities

    /// Convert display Y (origin top-left) to FITS Y (origin bottom-left).
    static func displayToFITSY(_ displayY: Double, naxis2: Int) -> Double {
        Double(naxis2 - 1) - displayY
    }

    /// 0-based FITS array indices of the pixel drawn under a display-space
    /// point. `pixels` is stored in file order (row 0 first) and the
    /// renderer draws buffer row `naxis2 - 1 - displayRow`, so the row
    /// flips. This is the convention `probe_fits_pixel` takes.
    static func arrayPixel(atDisplay point: CGPoint, naxis2: Int) -> (x: Int, y: Int) {
        FITSDisplayGrid(width: 0, height: naxis2).index(ofDisplay: point)
    }

    /// Readout text for one sample: 4 significant digits, "NaN" for blanks.
    static func formatPixelValue(_ value: Float) -> String {
        value.isFinite ? String(format: "%.4g", value) : "NaN"
    }

    /// Raw sample at 0-based FITS array indices; nil outside the image.
    func sample(x: Int, y: Int) -> Float? {
        guard let hdu = selectedHDU,
              x >= 0, y >= 0, x < hdu.header.naxis1, y < hdu.header.naxis2 else { return nil }
        let index = y * hdu.header.naxis1 + x
        return pixels.indices.contains(index) ? pixels[index] : nil
    }

    /// Readout text for the pixel drawn under a display-space point.
    func pixelValueText(atDisplay point: CGPoint) -> String? {
        guard let hdu = selectedHDU else { return nil }
        let pixel = Self.arrayPixel(atDisplay: point, naxis2: hdu.header.naxis2)
        return sample(x: pixel.x, y: pixel.y).map(Self.formatPixelValue)
    }

    /// Apply a linked crosshair from the shared store (marks crosshair as linked).
    /// FITSTabHostModel should call this instead of setting crosshairPixel directly.
    func applyLinkedCrosshair(pixel: CGPoint, ra: Double, dec: Double) {
        crosshairPixel = pixel
        crosshairRA = Sexagesimal.readoutHMS(degrees: ra)
        crosshairDec = Sexagesimal.readoutDMS(degrees: dec)
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

        if let text = pixelValueText(atDisplay: point) {
            crosshairValue = text
        }

        // Clear out-of-bounds state when user places a new crosshair
        crosshairOutOfBounds = false

        if let wcs {
            let fitsY = Self.displayToFITSY(point.y, naxis2: hdu.header.naxis2)
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            crosshairRA = Sexagesimal.readoutHMS(degrees: ra)
            crosshairDec = Sexagesimal.readoutDMS(degrees: dec)
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
        if let text = pixelValueText(atDisplay: point) {
            cursorPixelValue = text
        }

        if let wcs {
            let fitsY = Self.displayToFITSY(point.y, naxis2: hdu.header.naxis2)
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            cursorRA = Sexagesimal.readoutHMS(degrees: ra)
            cursorDec = Sexagesimal.readoutDMS(degrees: dec)
        }
    }

    // MARK: - Viewport

    func applyNorthUp() {
        guard let wcs else {
            Self.logger.warning("applyNorthUp: no WCS")
            return
        }
        // A view showing the whole image goes on showing it, turned; one
        // zoomed in on a part keeps its zoom (QA M6: the corners were cut).
        let wasFitted = isFitted(canvasSize: lastCanvasSize)
        viewport.rotation = -wcs.northAngle * .pi / 180.0
        viewport.flipX = wcs.hasParityFlip
        if wasFitted { fitZoomKeepingRotation(canvasSize: lastCanvasSize) }
        Self.logger.info("North Up: angle=\(wcs.northAngle)° rotation=\(self.viewport.rotation) flipX=\(self.viewport.flipX) pixelScale=\(wcs.pixelScaleArcsec)\"/px")
    }

    func resetViewport() {
        viewport = FITSViewport()
    }

    /// Where a Go To landed — one answer for the viewer and the agent tool.
    enum GoToOutcome: Equatable {
        /// Centred there, crosshair placed.
        case centred
        /// Off the image (view not moved): the 0-based FITS pixel it maps to.
        case offImage(x: Double, y: Double)
        /// No pixel for it here: no WCS, or the far side of the projection.
        case unplaceable
    }

    /// Which side of a `width`×`height` image a 0-based FITS pixel lies,
    /// e.g. "320 px left of and 15 px above the image". Row 0 is drawn at
    /// the bottom, so `y < 0` is below.
    static func whereItFalls(x: Double, y: Double, width: Int, height: Int) -> String {
        var sides: [String] = []
        if x < 0 { sides.append("\(Int((-x).rounded())) px left of") }
        if x >= Double(width) { sides.append("\(Int((x - Double(width - 1)).rounded())) px right of") }
        if y < 0 { sides.append("\(Int((-y).rounded())) px below") }
        if y >= Double(height) { sides.append("\(Int((y - Double(height - 1)).rounded())) px above") }
        return sides.isEmpty ? "on the image" : sides.joined(separator: " and ") + " the image"
    }

    /// Navigate viewport to center on a world coordinate (RA/Dec). Off the
    /// image the view stays put and the crosshair is not placed.
    @discardableResult
    func goToCoordinate(ra: Double, dec: Double) -> GoToOutcome {
        guard let wcs, let hdu = selectedHDU,
              let pixel = wcs.worldToPixel(ra: ra, dec: dec) else { return .unplaceable }

        let naxis1 = hdu.header.naxis1
        let naxis2 = hdu.header.naxis2
        guard pixel.x >= 0, pixel.x < Double(naxis1),
              pixel.y >= 0, pixel.y < Double(naxis2) else {
            Self.logger.info("goToCoordinate: (\(ra), \(dec)) → pixel (\(pixel.x), \(pixel.y)) outside \(naxis1)×\(naxis2)")
            return .offImage(x: pixel.x, y: pixel.y)
        }

        let displayY = Self.displayToFITSY(pixel.y, naxis2: naxis2)
        let imgPoint = CGPoint(x: pixel.x, y: displayY)
        placeCrosshair(at: imgPoint)
        centerOnPixel(imgPoint, canvasSize: lastCanvasSize)
        return .centred
    }

    /// Read-only pixel probe for the agent tools: value + sky at 0-based
    /// FITS array indices (astropy `all_pix2world(..., origin=0)`). `y = 0`
    /// is the first stored row, not the top of the canvas; display-space
    /// callers convert with ``arrayPixel(atDisplay:naxis2:)``. Returns nil
    /// when the pixel is outside the image.
    func probePixel(x: Int, y: Int) -> (value: Double?, ra: Double?, dec: Double?)? {
        guard let hdu = selectedHDU,
              x >= 0, y >= 0, x < hdu.header.naxis1, y < hdu.header.naxis2 else { return nil }
        let value = sample(x: x, y: y).flatMap { $0.isFinite ? Double($0) : nil }
        guard let wcs else { return (value, nil, nil) }
        let (ra, dec) = wcs.pixelToWorld(x: Double(x), y: Double(y))
        return (value, ra, dec)
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

    // MARK: - Coordinate Transforms (delegated to ViewportTransform)
    //
    // The trig math lives in `ViewportTransform` so it's testable without
    // spinning up the model. These shims package the current viewport +
    // image dimensions into a transform and call through.

    private func makeTransform(imgSize: CGSize, canvasSize: CGSize) -> ViewportTransform {
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
    private func fittedZoom(canvasSize: CGSize) -> Double? {
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
    private func fitZoomKeepingRotation(canvasSize: CGSize) {
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

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        await open(url: url)
    }
    #endif
}

extension FITSViewerModel: ViewerDocument {
    static var documentKind: String { "FITS file" }
    var isLoaded: Bool { file != nil }
}
