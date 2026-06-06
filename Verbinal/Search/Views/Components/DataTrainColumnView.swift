// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct DataTrainColumnView: View {
    /// Catalog-routed column heading. Runtime values from
    /// `ADQL.dataTrainColumnLabels` are wrapped with
    /// `LocalizedStringKey(_:)` at the call site — catalog miss falls
    /// back to the raw string.
    let title: LocalizedStringKey
    let options: [String]
    let selection: [String]
    let onToggle: (String) -> Void

    @State private var searchText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredOptions: [String] {
        if searchText.isEmpty { return options }
        return options.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                if !selection.isEmpty {
                    Text("(\(selection.count))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Filter…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredOptions, id: \.self) { option in
                            Button {
                                onToggle(option)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: selection.contains(option) ? "checkmark.square.fill" : "square")
                                        .font(.caption)
                                        .foregroundColor(selection.contains(option) ? .accentColor : .secondary)
                                    Text(option)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(option)
                        }
                    }
                }
                .onAppear { scrollToAnchor(proxy: proxy) }
                .onChange(of: searchText) { _, _ in scrollToAnchor(proxy: proxy) }
            }
            .frame(height: 160)
        }
        .frame(width: 130)
    }

    /// Scroll to the first selected option (or top if none). Anchors at top of viewport.
    private func scrollToAnchor(proxy: ScrollViewProxy) {
        let anchor = firstVisibleSelection ?? filteredOptions.first
        guard let anchor else { return }
        withAppAnimation(AppMotion.quick, reduceMotion: reduceMotion) {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    /// First option in the current filtered list that is also in the selection.
    private var firstVisibleSelection: String? {
        filteredOptions.first(where: { selection.contains($0) })
    }
}
