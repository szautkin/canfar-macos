// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Popover presenting every available column as a three-column grid of
/// checkboxes with bulk actions (Show All / Hide All / Reset) and a live
/// filter. Selections persist via ``SearchResultsModel/toggleColumnVisibility``
/// → ``SearchResultColumns/persistVisibility``.
struct ColumnsPickerPopover: View {
    @Bindable var model: SearchResultsModel
    @Environment(\.dismiss) private var dismiss
    @State private var filterText = ""

    private let gridColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(minimum: 120), spacing: 12, alignment: .leading),
        count: 3
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            gridBody
            Divider()
            footer
        }
        .frame(width: 560, height: 440)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Visible Columns")
                    .font(.headline)
                Text("\(String(visibleCount)) of \(String(model.columns.count)) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter columns", text: $filterText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear filter"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var gridBody: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 6) {
                ForEach(filteredColumns) { col in
                    Toggle(isOn: Binding(
                        get: { col.visible },
                        set: { _ in model.toggleColumnVisibility(col.id) }
                    )) {
                        Text(col.label)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .platformCheckboxToggle()
                    .help(Text(col.label))
                }
            }
            .padding(16)
        }
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #endif
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Show All") { model.setAllColumnsVisible(true) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(visibleCount == model.columns.count)

            Button("Hide All") { model.setAllColumnsVisible(false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(visibleCount == 0)

            Button("Reset to Defaults") { model.resetColumnVisibility() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Derived

    private var visibleCount: Int {
        model.columns.list.filter(\.visible).count
    }

    private var filteredColumns: [SearchResultColumn] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.columns.list }
        return model.columns.list.filter { col in
            col.label.lowercased().contains(query) || col.id.contains(query)
        }
    }
}
