// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// One compact tile in the AI Guide launchpad. Carries no tool rows — only the
/// category's title, a two-line summary, a tool count, and a subtle "has
/// overrides" dot — so the launchpad reads as an even matrix that the user taps
/// to open the centered ``AIGuideFocusPanel``.
///
/// Reuses the dashboard `GroupBox` + `Label` rhythm of ``AIGuideCategoryCard``;
/// it is a `Button` so it inherits free keyboard focus, Return activation, and
/// the `.isButton` trait. Tiles are a fixed height for an even grid, but grow
/// (switching to `minHeight`) at accessibility Dynamic Type sizes so the summary
/// never clips — legibility over evenness at huge type.
struct AIGuideCategoryTile: View {
    let category: AIGuideCatalog.Category
    let toolCount: Int
    let hasOverrides: Bool
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Let the tile grow instead of clamping to a fixed height once Dynamic Type
    /// is large enough that the two-line summary risks truncation — covers the
    /// xxLarge/xxxLarge gap, not only accessibility sizes.
    private var flexHeight: Bool { typeSize >= .xxLarge }

    var body: some View {
        // Subviews are extracted (cardBody / footer) to keep each expression
        // small — the inline Button>GroupBox>VStack tree tripped the SwiftUI
        // type-checker's complexity budget.
        Button(action: onOpen) { card }
            .buttonStyle(.plain)
            .help("Open \(category.title) — \(toolCount) tools")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(category.title), \(toolCount) tools" + (hasOverrides ? ", has overrides" : ""))
            .accessibilityHint("Opens this category to edit its tool descriptions")
            .accessibilityAddTraits(.isButton)
    }

    private var card: some View {
        GroupBox { cardBody }
            // Fixed height → even matrix; grows (minHeight) once type is large
            // enough that the 2-line summary risks clipping (xxLarge and up).
            .frame(height: flexHeight ? nil : 116)
            .frame(minHeight: flexHeight ? 116 : nil, alignment: .top)
            .contentShape(Rectangle())
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(category.title, systemImage: category.systemImage)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(category.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            footer
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            // Sits next to the count so it reads as a count qualifier, not a
            // stray element floating at the far edge.
            if hasOverrides {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text("^[\(toolCount) tool](inflect: true)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preference keys (launchpad → overlay geometry)

/// Collects each tile's frame, keyed by `category.id`, in the `"aiGuideRoot"`
/// coordinate space. The captured rect drives the focus panel's scale anchor so
/// the panel grows from the tapped tile's location — read-only, so it is immune
/// to the lazy grid recycling its cells mid-flight.
struct TileFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Reports the viewport size so the overlay can convert a tile's midpoint to a
/// `UnitPoint` scale anchor and cap the panel's height to the visible area.
struct RootSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
#endif
