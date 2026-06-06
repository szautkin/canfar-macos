// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// The centered focus panel an AI Guide tile expands into. It reuses the exact
/// `Label(category.title, systemImage:)` + overridden-dot + count rhythm of
/// ``AIGuideCategoryCard`` for its header, surfaces the category's summary as a
/// subtitle, then renders the literal ``AIGuideToolRow`` list inside an inner
/// `ScrollView` so tall categories (e.g. Storage's nine tools) scroll within the
/// panel instead of resizing it.
///
/// Because it embeds the unchanged ``AIGuideToolRow``, the inline accordion
/// editor, the overridden capsule, and the right-click "Reset to Default"
/// affordance stay byte-identical to the launchpad grid. The edit target lives
/// on ``AIGuideView`` (so it survives the open/close animation) and is threaded
/// through `editingToolName`. Esc / ⌘. are owned by ``AIGuideView``'s overlay
/// handler, which cancels an in-progress inline edit and closes the panel only
/// when no row is editing — so the Close button is pointer-only (no
/// `.cancelAction`, which is window-level and could otherwise fire mid-edit).
struct AIGuideFocusPanel: View {
    let category: AIGuideCatalog.Category
    let rows: [AIGuideTool]
    /// Host-owned edit target, threaded into each row.
    @Binding var editingToolName: String?
    /// Persist an override; `nil` on success, else an inline error string.
    let onSave: (_ toolName: String, _ description: String) -> String?
    let onReset: (AIGuideTool) -> Void
    let onClose: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if rows.contains(where: \.isOverridden) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("has overrides")
                    }
                    Spacer()
                    Text("^[\(rows.count) tool](inflect: true)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close \(category.title)")
                }
                Text(category.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
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
                    .padding(.trailing, 2)
                }
            }
            .padding(8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        // A crisp edge so the panel separates from the grid even when Reduce
        // Motion drops the backdrop blur (then only the scrim provides contrast).
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }
}
#endif
