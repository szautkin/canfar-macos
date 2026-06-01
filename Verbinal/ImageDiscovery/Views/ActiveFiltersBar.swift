// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Horizontal chips bar that visualises every active filter from
/// `PackageQuery`. Each chip shows a category prefix + value and an
/// `xmark` button that removes that single value — equivalent to
/// unchecking the matching checkbox in the LEFT pane.
///
/// Sits between the modal header and the two panes so the user sees
/// the current filter set without scrolling the left pane to find
/// the boxes they ticked.
///
/// Wraps to multiple lines when the chip count overflows the row,
/// so a 12-package selection doesn't cause horizontal scrolling.
struct ActiveFiltersBar: View {
    @Bindable var model: ImageDiscoveryModel

    var body: some View {
        let chips = makeChips()
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Active filters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        model.query = PackageQuery()
                        model.typeFilter = nil
                    } label: {
                        Label("Clear all", systemImage: "xmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear every active filter")
                }
                FilterChipFlow(spacing: 6) {
                    ForEach(chips) { chip in
                        chipView(chip)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.cardBackground)
        }
    }

    // MARK: - Chip rendering

    @ViewBuilder
    private func chipView(_ chip: Chip) -> some View {
        HStack(spacing: 4) {
            Text(chip.category)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(chip.value)
                .font(.caption2.monospaced())
            Button {
                chip.remove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this filter")
            .accessibilityLabel("Remove filter \(chip.category) \(chip.value)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.15))
        )
        .overlay(
            Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Chip model

    /// One filter entry. `remove` closes over the corresponding
    /// `PackageQuery` mutation so the chip view doesn't need to
    /// know which set it lives in.
    private struct Chip: Identifiable {
        let id: String
        let category: String
        let value: String
        let remove: () -> Void
    }

    private func makeChips() -> [Chip] {
        var chips: [Chip] = []

        if let type = model.typeFilter {
            chips.append(Chip(id: "type:\(type)", category: "Type",
                              value: type, remove: {
                model.typeFilter = nil
            }))
        }
        for value in model.query.osFamilies.sorted() {
            chips.append(Chip(id: "fam:\(value)", category: "OS",
                              value: value, remove: {
                model.query.osFamilies.remove(value)
            }))
        }
        for value in model.query.osVersions.sorted() {
            chips.append(Chip(id: "ver:\(value)", category: "Version",
                              value: value, remove: {
                model.query.osVersions.remove(value)
            }))
        }
        for value in model.query.python.sorted() {
            chips.append(Chip(id: "py:\(value)", category: "Python",
                              value: value, remove: {
                model.query.python.remove(value)
            }))
        }
        for value in model.query.r.sorted() {
            chips.append(Chip(id: "r:\(value)", category: "R",
                              value: value, remove: {
                model.query.r.remove(value)
            }))
        }
        for value in model.query.dpkg.sorted() {
            chips.append(Chip(id: "dpkg:\(value)", category: "apt",
                              value: value, remove: {
                model.query.dpkg.remove(value)
            }))
        }
        for value in model.query.rpm.sorted() {
            chips.append(Chip(id: "rpm:\(value)", category: "rpm",
                              value: value, remove: {
                model.query.rpm.remove(value)
            }))
        }
        for value in model.query.apk.sorted() {
            chips.append(Chip(id: "apk:\(value)", category: "apk",
                              value: value, remove: {
                model.query.apk.remove(value)
            }))
        }
        return chips
    }
}

/// Wrapping flow layout for the chips. Implemented with the
/// `Layout` protocol (macOS 13+) so chips wrap to additional rows
/// when the bar overflows. Avoids a third-party dependency for
/// what is otherwise a 30-line layout calculation.
private struct FilterChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var x: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
