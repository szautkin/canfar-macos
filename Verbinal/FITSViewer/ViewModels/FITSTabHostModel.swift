// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import CoreGraphics
import Observation
import os.log
import VerbinalKit

/// Manages multiple FITS viewer tabs with linked crosshair and blink comparison.
///
/// Uses a **pull-on-activation store pattern** (matching Windows):
/// - Active tab writes to shared store (RA/Dec, angular zoom) via callbacks
/// - On tab switch, the newly active tab reads from the store and applies locally
/// - Shared state is never pushed to hidden tabs
/// - Applying shared state skips callbacks to prevent feedback loops
///
/// Blink comparison uses an **overlay-fade pattern** (matching Windows FitsTabHost):
/// - Image B is rendered as a CGImage overlay on top of image A
/// - A 50ms timer smoothly animates `blinkOpacity` between 0 (show A) and 1 (show B)
/// - The active tab never switches — image A stays in the foreground
@Observable
@MainActor
final class FITSTabHostModel {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "FITSTabHost")

    var tabs: [FITSViewerModel] = []
    let linkedState = FITSLinkedState()

    /// Prevents feedback loops when applying shared state to a tab.
    private var isApplyingSharedState = false

    // MARK: - Blink State

    /// True while a blink session is active.
    var isBlinking = false
    /// True when blink animation is paused (keeps current opacity frozen).
    var isBlinkPaused = false
    /// Index of the primary (reference) tab.
    var blinkTabA: Int = 0
    /// Index of the overlay (comparison) tab.
    var blinkTabB: Int = 1
    /// Rendered CGImage of image B, overlaid on image A. Nil when not blinking.
    var blinkOverlayImage: CGImage?
    /// Alignment transform for the overlay. Nil when not blinking or WCS unavailable.
    var blinkTransform: BlinkTransform?
    /// Opacity of the overlay: 0 = show image A fully, 1 = show image B fully.
    var blinkOpacity: Double = 0
    /// Blink period in seconds (0.5–5.0s, matching Windows 500–5000ms range).
    var blinkInterval: TimeInterval = 1.0
    /// Current fade direction: +1 fading toward B, -1 fading toward A.
    private var blinkFadeDirection: Int = 1
    private var blinkTask: Task<Void, Never>?

    /// Active tab index — applies shared state on change (pull-on-activation).
    var activeTabIndex: Int = 0 {
        didSet {
            guard activeTabIndex != oldValue else { return }
            applySharedStateToActiveTab()
        }
    }

    var activeTab: FITSViewerModel? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    func addTab() -> FITSViewerModel {
        let model = FITSViewerModel()
        // Active tab writes to store on crosshair/zoom change
        model.onCrosshairPlaced = { [weak self, weak model] ra, dec in
            guard let self, let model else { return }
            self.writeToStore(crosshairFrom: model, ra: ra, dec: dec)
        }
        model.onPixelCrosshairPlaced = { [weak self, weak model] pixel in
            guard let self, let model else { return }
            self.writePixelToStore(from: model, pixel: pixel)
        }
        model.onZoomChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            self.writeToStore(zoomFrom: model)
        }
        tabs.append(model)
        activeTabIndex = tabs.count - 1
        return model
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        // Stop blink if the closing tab is involved in a blink session
        if isBlinking && (index == blinkTabA || index == blinkTabB) {
            stopBlink()
        }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = max(0, tabs.count - 1)
        }
    }

    func closeActiveTab() {
        closeTab(at: activeTabIndex)
    }

    func openFile(url: URL) async {
        let model = addTab()
        await model.open(url: url)
    }

    var tabCount: Int { tabs.count }
    var hasMultipleTabs: Bool { tabs.count > 1 }

    // MARK: - Store: Write (active tab → store)

    // Linked-state contract (writes):
    //
    // These `writeToStore(...)` methods are **non-blocking broadcasts with no
    // ordering guarantees**. The active tab pushes its latest crosshair / zoom
    // into `linkedState`; the value is *not* pushed to other tabs and there is
    // no acknowledgement or serialization beyond what `@MainActor` already
    // provides. Both the writes here and `applySharedStateToActiveTab()` (the
    // reader) are `@MainActor`, so every individual call runs to completion
    // without interleaving — the only concurrency model is "last writer on the
    // main actor wins". The `isApplyingSharedState` guard suppresses writes
    // that would otherwise fire *while* a read is applying state to a tab
    // (preventing a feedback loop); it does **not** impose any cross-tab
    // write/read ordering. Do not assume a write here is observed by a specific
    // tab, in a specific order, or at any time other than that tab's next
    // activation. Reads happen exactly once, on tab activation (pull pattern).

    /// Write crosshair position to shared store. Only stores — does NOT touch other tabs.
    func writeToStore(crosshairFrom sourceTab: FITSViewerModel, ra: Double, dec: Double) {
        guard linkedState.linkCrosshair, !isApplyingSharedState else { return }
        linkedState.sharedCrosshair = WorldPosition(ra: ra, dec: dec)
        linkedState.sharedPixel = sourceTab.crosshairPixel
        Self.logger.info("writeToStore crosshair: RA=\(ra) Dec=\(dec)")
    }

    /// Write crosshair pixel position to shared store (for images without WCS).
    func writePixelToStore(from sourceTab: FITSViewerModel, pixel: CGPoint) {
        guard linkedState.linkCrosshair, !isApplyingSharedState else { return }
        linkedState.sharedPixel = pixel
        Self.logger.info("writePixelToStore: pixel=(\(pixel.x), \(pixel.y))")
    }

    /// Write zoom/orientation to shared store. Only stores — does NOT touch other tabs.
    func writeToStore(zoomFrom sourceTab: FITSViewerModel) {
        guard linkedState.linkZoom, !isApplyingSharedState else { return }
        guard let wcs = sourceTab.wcs else { return }
        linkedState.sharedAngularZoom = wcs.pixelScaleArcsec / sourceTab.viewport.zoom
        // Store the source's North-relative user rotation for orientation matching
        let northRotation = -wcs.northAngle * .pi / 180.0
        linkedState.sharedUserRotation = sourceTab.viewport.rotation - northRotation
    }

    // MARK: - Store: Read (on tab activation → apply to active tab)

    /// Apply shared crosshair and zoom to the newly active tab.
    /// Called on tab switch (pull-on-activation pattern).
    ///
    /// Linked-state contract (reads): this is the *only* reader of the shared
    /// store and it runs exactly once per tab activation. It is `@MainActor`,
    /// like the `writeToStore(...)` broadcasters, so an apply never interleaves
    /// with a write — the main actor serializes the two. There is no need (and
    /// no mechanism) to wait for or order writes relative to this read: it
    /// simply consumes whatever happens to be in `linkedState` at activation
    /// time. See the "Linked-state contract (writes)" note above.
    func applySharedStateToActiveTab() {
        guard let tab = activeTab else { return }
        Self.logger.info("applySharedState: tabIdx=\(self.activeTabIndex) linkCrosshair=\(self.linkedState.linkCrosshair) hasCrosshair=\(self.linkedState.sharedCrosshair != nil) linkZoom=\(self.linkedState.linkZoom)")

        // Raise the feedback-loop guard for the duration of the apply: any
        // `writeToStore(...)` triggered re-entrantly by mutating this tab is
        // dropped (see the guard in each writer) so applying state can never
        // clobber the store we are reading from. The flag is set on entry and
        // cleared via `defer` so it is always balanced even on early `return`.
        isApplyingSharedState = true
        defer { isApplyingSharedState = false }

        // Apply shared crosshair: prefer WCS (RA/Dec), fall back to pixel position
        if linkedState.linkCrosshair {
            if let pos = linkedState.sharedCrosshair, tab.wcs != nil {
                applyCrosshair(to: tab, ra: pos.ra, dec: pos.dec)
            } else if let pixel = linkedState.sharedPixel {
                // Pixel-only fallback (no WCS on source or target)
                applyPixelCrosshair(to: tab, pixel: pixel)
            }
        }

        // Apply shared zoom + orientation
        if linkedState.linkZoom, let angularZoom = linkedState.sharedAngularZoom {
            applyZoom(to: tab, angularZoom: angularZoom)
        }
    }

    /// Apply a world coordinate crosshair to a tab without triggering callbacks.
    ///
    /// Uses `applyLinkedCrosshair` so the crosshair is rendered in linked style
    /// (dashed yellow) to distinguish it from user-placed crosshairs (solid red).
    /// If the pixel is outside the image bounds, sets `crosshairOutOfBounds` and
    /// stores the RA/Dec for display in the sidebar, but does NOT place the crosshair.
    private func applyCrosshair(to tab: FITSViewerModel, ra: Double, dec: Double) {
        guard let wcs = tab.wcs,
              let pixel = wcs.worldToPixel(ra: ra, dec: dec),
              let hdu = tab.selectedHDU else { return }

        let naxis1 = hdu.header.naxis1
        let naxis2 = hdu.header.naxis2

        guard pixel.x >= 0, pixel.x < Double(naxis1),
              pixel.y >= 0, pixel.y < Double(naxis2) else {
            Self.logger.info("Linked crosshair out of bounds: pixel=(\(pixel.x), \(pixel.y)) naxis=\(naxis1)×\(naxis2)")
            tab.crosshairOutOfBounds = true
            tab.outOfBoundsRA = FITSWCSTransform.formatRA(ra)
            tab.outOfBoundsDec = FITSWCSTransform.formatDec(dec)
            return
        }

        tab.crosshairOutOfBounds = false
        let displayY = FITSViewerModel.displayToFITSY(pixel.y, naxis2: naxis2)
        let crosshairPoint = CGPoint(x: pixel.x, y: displayY)
        tab.applyLinkedCrosshair(pixel: crosshairPoint, ra: ra, dec: dec)
        // Center viewport on crosshair so it's visible after tab switch
        tab.centerOnPixel(crosshairPoint, canvasSize: tab.lastCanvasSize)
    }

    /// Apply a pixel-position crosshair to a tab (fallback when WCS is unavailable).
    /// Checks bounds and applies as a linked crosshair.
    private func applyPixelCrosshair(to tab: FITSViewerModel, pixel: CGPoint) {
        guard let hdu = tab.selectedHDU else { return }
        let naxis1 = hdu.header.naxis1
        let naxis2 = hdu.header.naxis2

        guard pixel.x >= 0, pixel.x < Double(naxis1),
              pixel.y >= 0, pixel.y < Double(naxis2) else {
            Self.logger.info("Linked pixel crosshair out of bounds: (\(pixel.x), \(pixel.y)) vs \(naxis1)×\(naxis2)")
            tab.crosshairOutOfBounds = true
            tab.outOfBoundsRA = String(format: "px %.0f", pixel.x)
            tab.outOfBoundsDec = String(format: "py %.0f", pixel.y)
            return
        }

        tab.crosshairOutOfBounds = false
        tab.crosshairPixel = pixel
        tab.crosshairRA = String(format: "px %.0f", pixel.x)
        tab.crosshairDec = String(format: "py %.0f", pixel.y)
        tab.isLinkedCrosshair = true

        let pixelIdx = FITSViewerModel.pixelIndex(x: pixel.x, y: pixel.y, width: naxis1)
        if pixelIdx >= 0 && pixelIdx < tab.pixels.count {
            tab.crosshairValue = String(format: "%.4g", tab.pixels[pixelIdx])
        }
        // Center on crosshair so it's visible after tab switch
        tab.centerOnPixel(pixel, canvasSize: tab.lastCanvasSize)
    }

    /// Apply angular zoom and orientation to a tab without triggering callbacks.
    /// Clamps computed zoom to [0.05, 20] and sets a pending toast on the tab
    /// if the raw value was outside that range (indicating very different pixel scales).
    private func applyZoom(to tab: FITSViewerModel, angularZoom: Double) {
        guard let wcs = tab.wcs else { return }
        let rawZoom = wcs.pixelScaleArcsec / angularZoom
        let clampedZoom = max(FITSViewerConstants.zoomMin, min(FITSViewerConstants.zoomMax, rawZoom))
        if clampedZoom != rawZoom {
            Self.logger.info("Linked zoom clamped: raw=\(rawZoom) clamped=\(clampedZoom)")
            tab.pendingToast = String(localized: "Linked zoom clamped — images have very different pixel scales")
        }
        tab.viewport.zoom = clampedZoom
        if let userRotation = linkedState.sharedUserRotation {
            let targetNorth = -wcs.northAngle * .pi / 180.0
            tab.viewport.rotation = targetNorth + userRotation
        }
        // Center on crosshair after zoom change so it stays visible
        if let crosshair = tab.crosshairPixel {
            tab.centerOnPixel(crosshair, canvasSize: tab.lastCanvasSize)
        }
    }

    // MARK: - Blink Comparison

    /// Start blink comparison: image B overlaid on image A with smooth opacity fade.
    ///
    /// The active tab stays on tabA throughout — blink works via an overlay, not tab switching.
    /// Both images must have valid WCS for alignment; if WCS is missing on either, blink
    /// still runs but without alignment (overlay centered, no parity correction).
    func startBlink(tabA: Int, tabB: Int) {
        guard tabA < tabs.count, tabB < tabs.count, tabA != tabB else { return }
        stopBlink()

        blinkTabA = tabA
        blinkTabB = tabB

        // Stay on tabA — don't switch tabs
        activeTabIndex = tabA

        let tabAModel = tabs[tabA]
        let tabBModel = tabs[tabB]

        // Capture image B's current rendered output as the overlay
        blinkOverlayImage = tabBModel.renderedImage
        Self.logger.info("startBlink: tabA=\(tabA) tabB=\(tabB) overlayImage=\(tabBModel.renderedImage != nil) transform=\(self.blinkTransform != nil)")

        // Compute WCS alignment transform if both images have valid WCS
        blinkTransform = computeBlinkTransform(tabAModel: tabAModel, tabBModel: tabBModel)

        isBlinking = true
        isBlinkPaused = false
        blinkOpacity = 0
        blinkFadeDirection = 1

        // 50ms tick timer for smooth fade (matches Windows DispatcherTimer interval)
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { break }
                self.tickBlink()
            }
        }
    }

    /// Compute alignment transform for the blink overlay using WCS from both tabs.
    ///
    /// Uses tab A's crosshair as reference sky position if available; falls back to
    /// tab A's WCS center (CRVAL1/CRVAL2). Returns nil when either tab lacks WCS.
    private func computeBlinkTransform(
        tabAModel: FITSViewerModel,
        tabBModel: FITSViewerModel
    ) -> BlinkTransform? {
        guard let wcsA = tabAModel.wcs, let wcsB = tabBModel.wcs,
              let hduA = tabAModel.selectedHDU, let hduB = tabBModel.selectedHDU else {
            return nil
        }

        // Reference sky position: use crosshair if placed, else WCS center
        let referenceRA: Double
        let referenceDec: Double
        if let crosshair = tabAModel.crosshairPixel {
            let fitsY = FITSViewerModel.displayToFITSY(crosshair.y, naxis2: hduA.header.naxis2)
            let (ra, dec) = wcsA.pixelToWorld(x: crosshair.x, y: fitsY)
            referenceRA = ra
            referenceDec = dec
        } else {
            referenceRA = wcsA.crval1
            referenceDec = wcsA.crval2
        }

        // Display dimensions of image A (rendered at 1:1 before zoom/pan)
        let displayWidthA = Double(hduA.header.naxis1)
        let displayHeightA = Double(hduA.header.naxis2)

        // Canvas size from last known canvas dimensions of tab A
        let canvasWidth = tabAModel.lastCanvasSize.width
        let canvasHeight = tabAModel.lastCanvasSize.height

        return BlinkAligner.computeAlignedTransform(
            wcsA: wcsA,
            wcsB: wcsB,
            rotationA: tabAModel.viewport.rotation,
            zoomA: tabAModel.viewport.zoom,
            referenceRA: referenceRA,
            referenceDec: referenceDec,
            imageWidthB: hduB.header.naxis1,
            imageHeightB: hduB.header.naxis2,
            displayWidthA: displayWidthA,
            displayHeightA: displayHeightA,
            canvasWidth: Double(canvasWidth),
            canvasHeight: Double(canvasHeight)
        )
    }

    /// Advance the blink fade by one 50ms tick.
    ///
    /// Matches Windows `OnBlinkTick`: increments/decrements opacity by a fixed
    /// fraction per tick so the full cycle takes `blinkInterval` seconds.
    ///
    /// The `isBlinking` guard is the authoritative stop barrier: `stopBlink()`
    /// cancels the task *and* clears `isBlinking`, and because both this method
    /// and `stopBlink()` are `@MainActor`-isolated (no `await` between the
    /// task's cancellation check and this call) a tick can never mutate
    /// `blinkOpacity` against a stopped/torn-down session. `internal` (not
    /// `private`) only so the lifecycle can be unit-tested.
    func tickBlink() {
        guard isBlinking, !isBlinkPaused else { return }

        // Step size: fraction of [0,1] range advanced per 50ms tick.
        // Full period = blinkInterval seconds → 2 transitions (A→B and B→A).
        // Each transition spans the full range, so each takes blinkInterval/2 seconds.
        // Ticks per transition = (blinkInterval / 2) / 0.05 = blinkInterval * 10
        // Step per tick = 1 / (blinkInterval * 10) = 0.1 / blinkInterval
        let step = 0.05 / max(blinkInterval, 0.1)
        blinkOpacity += Double(blinkFadeDirection) * step

        if blinkOpacity >= 1.0 {
            blinkOpacity = 1.0
            blinkFadeDirection = -1
        } else if blinkOpacity <= 0.0 {
            blinkOpacity = 0.0
            blinkFadeDirection = 1
        }
    }

    // No custom deinit: the blink task captures `[weak self]` and exits on the
    // next 50 ms tick when self is deallocated, so the actor-isolated task handle
    // does not need to be touched from a nonisolated deinit.

    func stopBlink() {
        blinkTask?.cancel()
        blinkTask = nil
        isBlinking = false
        isBlinkPaused = false
        blinkOpacity = 0
        blinkFadeDirection = 1
        blinkOverlayImage = nil
        blinkTransform = nil
    }

    func toggleBlinkPause() {
        isBlinkPaused.toggle()
    }

    /// Show image A: freeze opacity at 0 (overlay fully transparent).
    func showBlinkA() {
        isBlinkPaused = true
        blinkOpacity = 0
        blinkFadeDirection = 1
    }

    /// Show image B: freeze opacity at 1 (overlay fully opaque).
    func showBlinkB() {
        isBlinkPaused = true
        blinkOpacity = 1
        blinkFadeDirection = -1
    }
}
