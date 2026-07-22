// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FileBrowserPanel: View {
    @Environment(AppState.self) private var appState
    var model: FileBrowserModel
    var onOpenFile: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button { model.goUp() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canGoUp)
                .accessibilityLabel("Go to parent folder")
                .help("Parent folder")

                Text(model.breadcrumbName)
                    .font(.caption.bold())
                    .lineLimit(1)

                Spacer()

                Toggle(isOn: Bindable(model).showOnlySupportedTypes) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Show only supported files")
                .accessibilityLabel("Show only supported files")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Filter
            TextField("Filter…", text: Bindable(model).filterText)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            Divider()

            // Sandbox denied this folder and the user hasn't granted it —
            // offer the powerbox grant instead of a raw permission error.
            if model.needsGrant {
                VStack(spacing: 8) {
                    Image(systemName: "lock.folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Verbinal needs your permission to read this folder.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button {
                        model.grantAccessToCurrentFolder()
                    } label: {
                        Label("Grant Access…", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }

            // Distinguish "couldn't load" / "some items unreadable" from an
            // actually-empty folder.
            if let error = model.loadError {
                Label("Couldn't load this folder: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else if model.loadSkippedCount > 0 {
                Label("\(model.loadSkippedCount) item\(model.loadSkippedCount == 1 ? "" : "s") could not be read",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

            // File list
            List(model.filteredNodes) { node in
                Button {
                    if node.isDirectory {
                        model.navigateInto(node)
                    } else {
                        onOpenFile(node.url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: node.icon)
                            .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Text(node.name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if !node.isDirectory {
                            Text(node.formattedSize)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .task {
            model.access = appState.localFolderAccess
            model.loadDirectory()
        }
    }
}
