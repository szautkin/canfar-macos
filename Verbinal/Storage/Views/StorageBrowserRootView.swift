// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct StorageBrowserRootView: View {
    var model: StorageBrowserModel

    @State private var newFolderName = ""
    @State private var showNewFolder = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            storageToolbar
            Divider()

            // Breadcrumb
            breadcrumbBar
            Divider()

            // File list
            if model.isLoading && model.nodes.isEmpty {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if model.hasError && model.nodes.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(model.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.refresh() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
            } else if model.nodes.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Empty folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                FileListView(model: model)
            }

            // Status bar
            Divider()
            statusBar
        }
        .task {
            await model.loadCurrentFolder()
        }
        .sheet(isPresented: $showNewFolder) {
            newFolderSheet
        }
    }

    // MARK: - Toolbar

    private var storageToolbar: some View {
        HStack(spacing: 8) {
            Button { Task { await model.goUp() } } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(model.currentPath.isEmpty)

            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 16)

            #if os(macOS)
            Button { Task { await model.uploadWithPicker() } } label: {
                Label("Upload", systemImage: "arrow.up.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isUploading)

            Button { Task { await model.downloadSelected() } } label: {
                Label("Download", systemImage: "arrow.down.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.selectedNode == nil || model.selectedNode?.isContainer == true)
            #endif

            Button { showNewFolder = true } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button { Task { await model.deleteSelected() } } label: {
                Label("Delete", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.selectedNode == nil)

            Spacer()

            if model.isLoading || model.isUploading {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Breadcrumb

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.breadcrumbs) { segment in
                    Button(segment.name) {
                        Task { await model.navigateTo(segment.path) }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(segment.path == model.currentPath ? .primary : .secondary)

                    if segment.path != model.currentPath {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.hasError {
                Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - New Folder Sheet

    private var newFolderSheet: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    newFolderName = ""
                    showNewFolder = false
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Create") {
                    Task {
                        await model.createFolder(name: newFolderName)
                        newFolderName = ""
                        showNewFolder = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
