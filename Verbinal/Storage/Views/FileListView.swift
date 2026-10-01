// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FileListView: View {
    var model: StorageBrowserModel
    @State private var nodeToDelete: VOSpaceNode?

    var body: some View {
        VStack(spacing: 0) {
            exposedSecretsBanner

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

            // Manual selection — SwiftUI `List(..., selection:)` is unreliable
            // on macOS with custom row content + gestures, which left Delete
            // permanently disabled. Single-click selects; double-click opens
            // folders (and is a no-op for files — use Download / context menu).
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sortedNodes) { node in
                        fileRow(node)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(rowBackground(for: node))
                            .onTapGesture(count: 2) {
                                Task { await model.openNode(node) }
                            }
                            .onTapGesture(count: 1) {
                                model.selectedNode = node
                            }
                            #if os(macOS)
                            .contextMenu {
                                if node.isContainer {
                                    Button("Open") {
                                        model.selectedNode = node
                                        Task { await model.openNode(node) }
                                    }
                                } else {
                                    Button("Download") {
                                        model.selectedNode = node
                                        Task { await model.downloadSelected() }
                                    }
                                    if node.isFITS {
                                        Button("Open in FITS Viewer") {
                                            model.selectedNode = node
                                            Task { await model.openInFITSViewer(node) }
                                        }
                                    }
                                }
                                Button("Copy Path") {
                                    PlatformClipboard.copy(model.vospaceURI(for: node))
                                }
                                if node.isPublic {
                                    Button("Make Private") {
                                        Task { await model.makePrivate([node]) }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    model.selectedNode = node
                                    nodeToDelete = node
                                }
                            }
                            #endif
                            // One element per row — an item named by the file, its kind,
                            // size and date as its value; its action selects it, as a
                            // click does — so VoiceOver reads it as a row, and an
                            // assistant can name and select it (plan 27).
                            .pointableItem(node.name, whole: true) { model.selectedNode = node }
                            .accessibilityValue(Text(rowDetails(node)))
                            .accessibilityAddTraits(model.selectedNode?.id == node.id ? .isSelected : [])
                            .accessibilityAction(named: "Delete") {
                                model.selectedNode = node
                                nodeToDelete = node
                            }
                    }
                }
            }
            .confirmationDialog("Delete \(nodeToDelete?.name ?? "")?", isPresented: Binding(
                get: { nodeToDelete != nil },
                set: { if !$0 { nodeToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let node = nodeToDelete {
                        model.selectedNode = node
                        Task { await model.deleteSelected() }
                    }
                    nodeToDelete = nil
                }
            } message: {
                Text(nodeToDelete?.isContainer == true
                     ? "This folder and its contents will be permanently deleted."
                     : "This file will be permanently deleted from VOSpace.")
            }
        }
    }

    /// Public files here that usually hold secrets, said once above the
    /// list, with the way to close them.
    @ViewBuilder
    private var exposedSecretsBanner: some View {
        let exposed = model.exposedSecrets
        if !exposed.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text(String(localized: "Anyone can read \(exposed.map(\.name).joined(separator: ", ")) — files like these usually hold secrets."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(exposed.count == 1 ? String(localized: "Make Private") : String(localized: "Make All Private")) {
                    Task { await model.makePrivate(exposed) }
                }
                .controlSize(.small)
                .disabled(model.isBusy)
                .pointable("storage.makePrivate")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }

    private func rowBackground(for node: VOSpaceNode) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(model.selectedNode?.id == node.id
                  ? Color.accentColor.opacity(0.18)
                  : Color.clear)
    }

    private func sortableHeader(_ title: LocalizedStringKey, key: StorageBrowserModel.SortKey) -> some View {
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

    /// What VoiceOver says of a row after its name: folder or file, size,
    /// when it changed, and the warning a public secret carries.
    private func rowDetails(_ node: VOSpaceNode) -> String {
        let kind = node.isContainer ? String(localized: "Folder") : String(localized: "File")
        let warning = node.isExposedSecret ? ", " + String(localized: "Public, and usually holds secrets") : ""
        return "\(kind), \(node.formattedSize), \(node.formattedDate)\(warning)"
    }

    private func fileRow(_ node: VOSpaceNode) -> some View {
        HStack(spacing: 0) {
            Image(systemName: node.icon)
                .frame(width: 30)
                .foregroundStyle(node.isContainer ? Color.accentColor : Color.secondary)

            HStack(spacing: 4) {
                Text(node.name)
                    .font(.caption)
                    .lineLimit(1)
                if node.isExposedSecret {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(String(localized: "Public — anyone can read it, and files like this usually hold secrets"))
                        .accessibilityLabel(String(localized: "Public, and usually holds secrets"))
                }
            }
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
