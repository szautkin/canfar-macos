// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SavedQueriesView: View {
    var store: SavedQueryStore
    var onRun: (String) -> Void
    var onLoad: (String) -> Void
    var currentQuery: String
    @State private var editingId: UUID?
    @State private var editingName = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Saved Queries", systemImage: "bookmark")
                        .font(.caption.bold())
                    Spacer()
                    if !store.queries.isEmpty {
                        Button("Clear") { store.clear() }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                    }
                }

                // Save current button
                if !currentQuery.isEmpty {
                    Button {
                        let name = "Query \u{2014} \(formatDate(Date()))"
                        store.save(SavedQuery(name: name, adql: currentQuery))
                    } label: {
                        Label("Save Current Query", systemImage: "plus.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if store.queries.isEmpty {
                    HStack {
                        Spacer()
                        Text("No saved queries")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.queries) { query in
                                queryCard(query)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    @ViewBuilder
    private func queryCard(_ query: SavedQuery) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if editingId == query.id {
                    TextField("Name", text: $editingName, onCommit: {
                        store.rename(query, to: editingName)
                        editingId = nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                } else {
                    Text(query.name)
                        .font(.caption2.bold())
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            editingId = query.id
                            editingName = query.name
                        }
                }
                Spacer()
                Text(formatDate(query.savedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(query.adql.prefix(120) + (query.adql.count > 120 ? "..." : ""))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack {
                Button("Run") { onRun(query.adql) }
                Button("Load") { onLoad(query.adql) }
                Spacer()
                Button("Remove", role: .destructive) { store.remove(query) }
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
