// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import CoreGraphics
import Observation

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

    /// Write crosshair position to shared store. Only stores — does NOT touch other tabs.
    func writeToStore(crosshairFrom sourceTab: FITSViewerModel, ra: Double, dec: Double) {
        guard linkedState.linkCrosshair, !isApplyingSharedState else { return }
        linkedState.sharedCrosshair = (ra: ra, dec: dec)
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
    func applySharedStateToActiveTab() {
        guard let tab = activeTab else { return }

        isApplyingSharedState = true
        defer { isApplyingSharedState = false }

        // Apply shared crosshair
        if linkedState.linkCrosshair, let shared = linkedState.sharedCrosshair {
            applyCrosshair(to: tab, ra: shared.ra, dec: shared.dec)
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
    private func applyCrosshair(to tab: FITSViewerModel, ra: Double, dec: Double) {
        guard let wcs = tab.wcs,
              let pixel = wcs.worldToPixel(ra: ra, dec: dec),
              let hdu = tab.selectedHDU else { return }
        let displayY = Double(hdu.header.naxis2 - 1) - pixel.y
        tab.applyLinkedCrosshair(
            pixel: CGPoint(x: pixel.x, y: displayY),
            ra: ra,
            dec: dec
        )
    }

    /// Apply angular zoom and orientation to a tab without triggering callbacks.
    private func applyZoom(to tab: FITSViewerModel, angularZoom: Double) {
        guard let wcs = tab.wcs else { return }
        tab.viewport.zoom = wcs.pixelScaleArcsec / angularZoom
        if let userRotation = linkedState.sharedUserRotation {
            let targetNorth = -wcs.northAngle * .pi / 180.0
            tab.viewport.rotation = targetNorth + userRotation
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
            let fitsY = Double(hduA.header.naxis2 - 1) - crosshair.y
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
    private func tickBlink() {
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
