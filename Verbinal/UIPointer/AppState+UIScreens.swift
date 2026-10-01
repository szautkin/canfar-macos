// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The names of the places on screen, as an assistant reads them — one
/// spelling for `get_current_view` and for every element listed (plan 27).
extension AppState {
    /// The main window's place: the mode, and Search's tab when it is not
    /// the form (`search.results`, `search.adql`).
    var screenName: String {
        guard currentMode == .search, searchModel.selectedTab != .search else { return currentMode.key }
        return "\(currentMode.key).\(searchModel.selectedTab.rawValue)"
    }

    /// A window's place, by its kind; for a sheet, by the window it is on.
    func screenName(of kind: UIWindowRef.Kind, parentScreen: String?, title: String) -> String {
        switch kind {
        case .main:
            return screenName
        case .settings:
            return "settings.\(settingsSection.rawValue)"
        case .sheet:
            let parent = parentScreen ?? "window"
            if parent == screenName, let sheet = activeSheet { return "sheet.\(sheet.rawValue)" }
            return "\(parent).sheet"
        case .other:
            let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return words.isEmpty ? "window" : "window." + words.joined(separator: "-")
        }
    }
}
