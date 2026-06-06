// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// Full-width summary header for the AI Guide screen: the intro blurb, live stat
/// chips (tool / overridden / category counts), and a filter field bound to the
/// view's search text. `ViewThatFits(in: .horizontal)` lays the search field
/// beside the title block when wide and drops it to its own row when narrow.
struct AIGuideSummaryHeader: View {
    let totalTools: Int
    let overriddenCount: Int
    let categoryCount: Int
    @Binding var searchText: String
    /// Number of matching tools while a query is active; `nil` when search is empty.
    let matchCount: Int?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        titleBlock
                        Spacer(minLength: 12)
                        searchField
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        titleBlock
                        searchField
                    }
                }
                if let matchCount {
                    Text("\(matchCount) of \(totalTools) tools match “\(searchText)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Re-tune how the AI agent sees each tool. Your edits override the built-in description the MCP server advertises.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                statChip("\(totalTools) tools", "wrench.and.screwdriver")
                if overriddenCount > 0 {
                    statChip("\(overriddenCount) overridden", "pencil.circle")
                }
                statChip("\(categoryCount) categories", "rectangle.3.group")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter tools…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        .frame(maxWidth: 280)
    }

    private func statChip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}
#endif
