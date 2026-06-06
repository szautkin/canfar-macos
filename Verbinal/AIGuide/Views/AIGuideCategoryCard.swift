// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// One tiled category widget in the AI Guide grid. Structurally the dashboard
/// `GroupBox` + `Label` header rhythm: a category title, a tinted "has
/// overrides" dot, a tool count, then divided ``AIGuideToolRow``s.
///
/// Fills its grid cell and stays top-aligned so a row of cards with differing
/// heights reads as deliberate spacing rather than a stretched card.
struct AIGuideCategoryCard: View {
    let category: AIGuideCatalog.Category
    let rows: [AIGuideTool]
    /// Card-owned edit target — one-at-a-time within this card.
    @State private var editingToolName: String?
    /// Persist an override; `nil` on success, else an inline error string.
    let onSave: (_ toolName: String, _ description: String) -> String?
    let onReset: (AIGuideTool) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if rows.contains(where: \.isOverridden) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("has overrides")
                    }
                    Text("\(rows.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    AIGuideToolRow(
                        row: row,
                        categoryTitle: nil,
                        editingToolName: $editingToolName,
                        onSave: onSave,
                        onReset: { onReset(row) }
                    )
                    if row.id != rows.last?.id { Divider() }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
