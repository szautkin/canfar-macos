// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The panels a person can hide, by name — what `open_ui` opens and
/// `close_ui` closes (plan 27 C). A panel is shown or hidden by app state,
/// never by pressing its toggle.
enum UIPanel: String, CaseIterable, Sendable {
    /// The file browser beside the main content (⌘B).
    case fileBrowser

    var id: String { "panel.\(rawValue)" }

    var name: String {
        switch self {
        case .fileBrowser: String(localized: "File browser")
        }
    }

    /// The panel `target` names — by its id, its name, or its toggle's words.
    static func named(_ target: String) -> UIPanel? {
        let wanted = UIPointerMatcher.normalise(target)
        guard !wanted.isEmpty else { return nil }
        return allCases.first { panel in
            [panel.id, panel.rawValue, panel.name, "Show \(panel.name)", "Hide \(panel.name)"]
                .map(UIPointerMatcher.normalise).contains(wanted)
        }
    }
}

extension AppState {
    func isShown(_ panel: UIPanel) -> Bool {
        switch panel {
        case .fileBrowser: fileBrowserShown
        }
    }

    func setShown(_ panel: UIPanel, _ shown: Bool) {
        switch panel {
        case .fileBrowser: fileBrowserShown = shown
        }
    }
}
