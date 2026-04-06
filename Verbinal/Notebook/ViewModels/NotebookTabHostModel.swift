// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages multiple notebook tabs.
@Observable
@MainActor
final class NotebookTabHostModel {
    var tabs: [NotebookModel] = []
    var activeTabIndex: Int = 0

    var activeTab: NotebookModel? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    var hasUnsavedChanges: Bool {
        tabs.contains { $0.isDirty }
    }

    func newTab() {
        let model = NotebookModel()
        tabs.append(model)
        activeTabIndex = tabs.count - 1
    }

    func openFile(url: URL) throws {
        // Check if already open
        if let idx = tabs.firstIndex(where: { $0.filePath == url }) {
            activeTabIndex = idx
            return
        }
        let model = NotebookModel()
        try model.openFile(url: url)
        tabs.append(model)
        activeTabIndex = tabs.count - 1
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
}
