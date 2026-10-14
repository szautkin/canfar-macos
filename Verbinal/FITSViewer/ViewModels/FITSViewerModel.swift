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
    nonisolated static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "FITSViewer")
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
    /// The box being dragged out, in canvas points; nil when none is.
    var areaBand: CGRect?

    // Mouse readout
    var cursorRA: String = ""
    var cursorDec: String = ""
    var cursorPixelValue: String = ""

    // State
    /// Empty, opening (how far it has got), failed (why), or open (plan 38).
    let document = Machine<DocumentMachine>(.empty)
    /// Files opened lately, for the empty screen.
    @ObservationIgnored var recentFiles = RecentFiles.fits
    var fileURL: URL?
    /// What the selected HDU shows when it is a table — its spectrum, or
    /// its columns — rather than a picture of its rows (plan 17 U4, QA N1).
    var table: FITSTableContent?
    var lastCanvasSize: CGSize = CGSize(width: 800, height: 600)

    var selectedHDU: FITSHDUnit? {
        guard let file, selectedHDUIndex < file.hdus.count else { return nil }
        return file.hdus[selectedHDUIndex]
    }

    /// What a figure of the file is called, from the HDU shown and the primary.
    var figureCaption: FITSFigureCaption {
        FITSFigureCaption(headers: [selectedHDU?.header, file?.hdus.first?.header].compactMap { $0 }, fileURL: fileURL)
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
        document.send(.begin)
        fileURL = url

        // For files saved via NSSavePanel and resolved from a security-scoped
        // bookmark (Research downloads), the sandbox requires
        // start/stopAccessingSecurityScopedResource() around the read. The
        // call is a safe no-op for non-scoped URLs (NSOpenPanel-picked
        // files already have process-scoped grants), so we always pair it.
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }

        do {
            document.send(.stage(String(localized: "Reading the header")))
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
                document.send(.opened)
                return
            }
            document.send(.stage(Self.readingStage(of: firstImageHDU)))
            let image = try await Task.detached { try LoadedImage(data: data, hdu: firstImageHDU) }.value
            document.send(.stage(String(localized: "Drawing")))

            file = fitsFile
            selectedHDUIndex = firstImageHDU.id
            table = nil
            apply(image)
            Self.logger.info("Loaded \(image.pixels.count) pixels (drawn at \(image.picture.width)×\(image.picture.height)), HDUs=\(fitsFile.hdus.count), WCS=\(fitsFile.firstImageHDU?.wcs != nil)")

            await renderImageAsync(nextRender())
            fitToWindow(canvasSize: lastCanvasSize)
            recentFiles.add(url)
            document.send(.opened)
        } catch {
            Self.logger.error("Failed to open FITS: \(error.localizedDescription, privacy: .public)")
            document.send(.failed(Problem(error)))
        }
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
                document.send(.failed(Problem(error)))
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
            document.send(.failed(Problem(error)))
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
        guard selectedHDU != nil, !pixels.isEmpty else { isRendering = false; return }
        renderTask?.cancel()
        let generation = nextRender()
        renderTask = Task { await renderImageAsync(generation) }
    }

    /// A new render's number; the image is busy until the newest is drawn.
    private func nextRender() -> Int {
        renderGeneration += 1
        isRendering = true
        return renderGeneration
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
        // Busy from the moment it is asked for, not only once the wait is over.
        if selectedHDU != nil, !pixels.isEmpty { isRendering = true }
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

    /// True from when a render is asked for until the newest one is drawn
    /// (drives the spinners on the image and in the sidebar).
    var isRendering = false
    /// The newest render's number: an older one, superseded, finishing
    /// never says the image is drawn while the newer one is still at it.
    private var renderGeneration = 0

    private func renderImageAsync(_ generation: Int) async {
        guard let hdu = selectedHDU, !pixels.isEmpty else {
            if generation == renderGeneration { isRendering = false }
            return
        }
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
            if generation == renderGeneration { isRendering = false }
            return
        }
        renderedImage = image
        if generation == renderGeneration { isRendering = false }
    }

    /// Callback for linked crosshair (WCS) — set by tab host.
    var onCrosshairPlaced: (@MainActor (Double, Double) -> Void)?
    /// Callback for linked crosshair (pixel-only, no WCS) — set by tab host.
    var onPixelCrosshairPlaced: (@MainActor (CGPoint) -> Void)?
    /// Callback for linked zoom — set by tab host.
    var onZoomChanged: (@MainActor () -> Void)?
    /// Callback for "Search at Position" context menu.
    var onSearchAtPosition: (@MainActor (Double, Double) -> Void)?
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

}

extension FITSViewerModel: ViewerDocument {
    static var documentKind: String { "FITS file" }
}
