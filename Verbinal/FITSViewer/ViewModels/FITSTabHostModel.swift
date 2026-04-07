// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages multiple FITS viewer tabs with linked crosshair and blink comparison.
///
/// Uses a **pull-on-activation store pattern** (matching Windows):
/// - Active tab writes to shared store (RA/Dec, angular zoom) via callbacks
/// - On tab switch, the newly active tab reads from the store and applies locally
/// - Shared state is never pushed to hidden tabs
/// - Applying shared state skips callbacks to prevent feedback loops
@Observable
@MainActor
final class FITSTabHostModel {
    var tabs: [FITSViewerModel] = []
    let linkedState = FITSLinkedState()

    /// Prevents feedback loops when applying shared state to a tab.
    private var isApplyingSharedState = false

    // Blink state
    var isBlinking = false
    var isBlinkPaused = false
    var blinkTabA: Int = 0
    var blinkTabB: Int = 1
    var blinkOpacity: Double = 1.0
    var blinkInterval: TimeInterval = 0.8
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
    private func applyCrosshair(to tab: FITSViewerModel, ra: Double, dec: Double) {
        guard let wcs = tab.wcs,
              let pixel = wcs.worldToPixel(ra: ra, dec: dec),
              let hdu = tab.selectedHDU else { return }
        let displayY = Double(hdu.header.naxis2 - 1) - pixel.y
        tab.crosshairPixel = CGPoint(x: pixel.x, y: displayY)
        tab.crosshairRA = FITSWCSTransform.formatRA(ra)
        tab.crosshairDec = FITSWCSTransform.formatDec(dec)
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

    func startBlink(tabA: Int, tabB: Int) {
        guard tabA < tabs.count, tabB < tabs.count, tabA != tabB else { return }
        blinkTabA = tabA
        blinkTabB = tabB
        isBlinking = true
        isBlinkPaused = false

        blinkTask = Task { [weak self] in
            var showA = true
            while !Task.isCancelled {
                guard let self else { break }
                if !self.isBlinkPaused {
                    self.activeTabIndex = showA ? self.blinkTabA : self.blinkTabB
                    showA.toggle()
                }
                try? await Task.sleep(for: .seconds(self.blinkInterval))
            }
        }
    }

    func stopBlink() {
        blinkTask?.cancel()
        blinkTask = nil
        isBlinking = false
        isBlinkPaused = false
        blinkOpacity = 1.0
    }

    func toggleBlinkPause() {
        isBlinkPaused.toggle()
    }

    func showBlinkA() {
        isBlinkPaused = true
        activeTabIndex = blinkTabA
    }

    func showBlinkB() {
        isBlinkPaused = true
        activeTabIndex = blinkTabB
    }
}
