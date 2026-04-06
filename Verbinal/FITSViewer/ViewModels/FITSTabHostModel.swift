// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages multiple FITS viewer tabs.
@Observable
@MainActor
final class FITSTabHostModel {
    var tabs: [FITSViewerModel] = []
    var activeTabIndex: Int = 0

    var activeTab: FITSViewerModel? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    func addTab() -> FITSViewerModel {
        let model = FITSViewerModel()
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

    /// Open a file in a new tab.
    func openFile(url: URL) async {
        let model = addTab()
        await model.open(url: url)
    }

    var tabCount: Int { tabs.count }
    var hasMultipleTabs: Bool { tabs.count > 1 }
}
