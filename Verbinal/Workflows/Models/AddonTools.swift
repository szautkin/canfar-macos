// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The tools an add-on brings, by add-on: not Verbinal's own (plan 30 G).
/// A workflow step names them on an `Add-on:` line. They apply on a Mac
/// where that add-on is installed; elsewhere the step's own `Tool:` does —
/// `run_code` on Remote Compute for analysis.
enum AddonTools {
    static let notebook = "com.codebg.Verbinal.addon.notebook"

    static let byAddon: [String: Set<String>] = [
        notebook: ["create_analysis_notebook", "create_notebook", "get_notebook", "list_notebooks",
                   "list_open_notebooks", "open_notebook", "run_all_cells", "run_cell", "save_notebook"],
    ]

    static var all: Set<String> { Set(byAddon.values.joined()) }

    /// Whether every one of `tools` comes with an add-on installed here.
    static func available(_ tools: [String], installed: Set<String>) -> Bool {
        !tools.isEmpty && tools.allSatisfy { tool in
            byAddon.contains { installed.contains($0.key) && $0.value.contains(tool) }
        }
    }
}
