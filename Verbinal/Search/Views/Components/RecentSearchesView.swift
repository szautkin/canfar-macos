// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct RecentSearchesView: View {
    var store: RecentSearchStore
    var onLoad: (SearchFormSnapshot) -> Void
    @State private var filterText = ""
    @State private var editingId: UUID?
    @State private var editingName = ""

    private var filteredSearches: [RecentSearch] {
        guard !filterText.isEmpty else { return store.searches }
        let query = filterText.lowercased()
        return store.searches.filter {
            $0.name.lowercased().contains(query) ||
            $0.formSnapshot.filterSummary().lowercased().contains(query)
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Recent Searches", systemImage: "clock.arrow.circlepath")
                        .font(.caption.bold())
                    Spacer()
                    if !store.searches.isEmpty {
                        Button("Clear") { store.clear() }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                    }
                }

                if !store.searches.isEmpty {
                    TextField("Filter...", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                }

                if filteredSearches.isEmpty {
                    HStack {
                        Spacer()
                        Text(store.searches.isEmpty ? "No recent searches" : "No matches")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(filteredSearches) { search in
                                searchCard(search)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    @ViewBuilder
    private func searchCard(_ search: RecentSearch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if editingId == search.id {
                    TextField("Name", text: $editingName, onCommit: {
                        store.rename(search, to: editingName)
                        editingId = nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                } else {
                    Text(search.name)
                        .font(.caption2.bold())
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            editingId = search.id
                            editingName = search.name
                        }
                }
                Spacer()
                Text(formatDate(search.savedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(search.formSnapshot.filterSummary())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Button("Load") { onLoad(search.formSnapshot) }
                Spacer()
                Button("Remove", role: .destructive) { store.remove(search) }
            }
            .buttonStyle(.borderless)
            .font(.caption2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}
