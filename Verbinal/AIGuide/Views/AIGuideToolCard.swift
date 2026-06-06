// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// A flat-search-result card: a `GroupBox` wrapping a single ``AIGuideToolRow``
/// with the tool's category surfaced as a subtitle. A `minHeight` keeps a row
/// of result cards visually aligned even when descriptions differ in length.
struct AIGuideToolCard: View {
    let row: AIGuideTool
    let categoryTitle: String
    /// Card-owned edit target — independent of other result cards.
    @State private var editingToolName: String?
    /// Persist an override; `nil` on success, else an inline error string.
    let onSave: (_ toolName: String, _ description: String) -> String?
    let onReset: () -> Void

    var body: some View {
        GroupBox {
            AIGuideToolRow(
                row: row,
                categoryTitle: categoryTitle,
                editingToolName: $editingToolName,
                onSave: onSave,
                onReset: onReset
            )
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A floor only — the expanded inline editor grows the card past it,
        // while collapsed cards stay aligned.
        .frame(minHeight: 120)
        .accessibilityElement(children: .contain)
    }
}
#endif
