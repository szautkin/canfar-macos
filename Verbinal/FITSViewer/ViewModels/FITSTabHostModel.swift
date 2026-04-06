// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages multiple FITS viewer tabs with linked crosshair and blink comparison.
@Observable
@MainActor
final class FITSTabHostModel {
    var tabs: [FITSViewerModel] = []
    var activeTabIndex: Int = 0
    let linkedState = FITSLinkedState()

    // Blink state
    var isBlinking = false
    var blinkTabA: Int = 0
    var blinkTabB: Int = 1
    var blinkOpacity: Double = 1.0
    private var blinkTask: Task<Void, Never>?

    var activeTab: FITSViewerModel? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    func addTab() -> FITSViewerModel {
        let model = FITSViewerModel()
        // Wire linked crosshair callback
        model.onCrosshairPlaced = { [weak self, weak model] ra, dec in
            guard let self, let model else { return }
            self.propagateCrosshair(from: model, ra: ra, dec: dec)
        }
        model.onZoomChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            self.propagateZoom(from: model)
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

    // MARK: - Linked Crosshair

    /// When a crosshair is placed in one tab, propagate to all others via WCS.
    func propagateCrosshair(from sourceTab: FITSViewerModel, ra: Double, dec: Double) {
        guard linkedState.linkCrosshair else { return }
        linkedState.sharedCrosshair = (ra: ra, dec: dec)

        for tab in tabs where tab.id != sourceTab.id {
            if let wcs = tab.wcs, let pixel = wcs.worldToPixel(ra: ra, dec: dec) {
                // Convert FITS pixel (0-based) to display pixel (Y-flipped)
                if let hdu = tab.selectedHDU {
                    let displayY = Double(hdu.header.naxis2 - 1) - pixel.y
                    tab.crosshairPixel = CGPoint(x: pixel.x, y: displayY)
                    tab.crosshairRA = FITSWCSTransform.formatRA(ra)
                    tab.crosshairDec = FITSWCSTransform.formatDec(dec)
                }
            }
        }
    }

    // MARK: - Linked Zoom

    /// When zoom changes in one tab, match angular extent in all others.
    func propagateZoom(from sourceTab: FITSViewerModel) {
        guard linkedState.linkZoom, let sourceWCS = sourceTab.wcs else { return }
        let angularZoom = sourceWCS.pixelScaleArcsec / sourceTab.viewport.zoom
        linkedState.sharedAngularZoom = angularZoom

        for tab in tabs where tab.id != sourceTab.id {
            if let wcs = tab.wcs {
                tab.viewport.zoom = wcs.pixelScaleArcsec / angularZoom
            }
        }
    }

    // MARK: - Blink Comparison

    func startBlink(tabA: Int, tabB: Int, interval: TimeInterval = 0.8) {
        guard tabA < tabs.count, tabB < tabs.count, tabA != tabB else { return }
        blinkTabA = tabA
        blinkTabB = tabB
        isBlinking = true

        blinkTask = Task {
            var showA = true
            while !Task.isCancelled {
                blinkOpacity = showA ? 1.0 : 0.0
                activeTabIndex = showA ? blinkTabA : blinkTabB
                showA.toggle()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopBlink() {
        blinkTask?.cancel()
        blinkTask = nil
        isBlinking = false
        blinkOpacity = 1.0
    }
}
