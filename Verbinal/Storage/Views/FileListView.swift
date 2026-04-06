// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FileListView: View {
    var model: StorageBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            // Sortable header
            HStack(spacing: 0) {
                Text("")
                    .frame(width: 30)

                sortableHeader("Name", key: .name)
                    .frame(maxWidth: .infinity, alignment: .leading)

                sortableHeader("Size", key: .size)
                    .frame(width: 80, alignment: .trailing)

                sortableHeader("Modified", key: .date)
                    .frame(width: 140, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)

            Divider()

            // File rows
            List(model.sortedNodes, selection: Binding(
                get: { model.selectedNode?.id },
                set: { newID in
                    model.selectedNode = model.sortedNodes.first { $0.id == newID }
                }
            )) {
                node in
                fileRow(node)
                    .tag(node.id)
                    .onTapGesture(count: 2) {
                        Task { await model.openNode(node) }
                    }
                    #if os(macOS)
                    .contextMenu {
                        if !node.isContainer {
                            Button("Download") { Task {
                                model.selectedNode = node
                                await model.downloadSelected()
                            }}
                        }
                        Button("Copy Path") {
                            let uri = model.vospaceURI(for: node)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(uri, forType: .string)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            model.selectedNode = node
                            Task { await model.deleteSelected() }
                        }
                    }
                    #endif
            }
            .listStyle(.plain)
        }
    }

    private func sortableHeader(_ title: String, key: StorageBrowserModel.SortKey) -> some View {
        Button {
            model.toggleSort(key)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.bold())
                if model.sortKey == key {
                    Image(systemName: model.sortOrder == .ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ node: VOSpaceNode) -> some View {
        HStack(spacing: 0) {
            Image(systemName: node.icon)
                .frame(width: 30)
                .foregroundColor(node.isContainer ? .accentColor : .secondary)

            Text(node.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(node.formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(node.formattedDate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
        }
    }
}
