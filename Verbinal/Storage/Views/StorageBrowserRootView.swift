// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct StorageBrowserRootView: View {
    var model: StorageBrowserModel

    @State private var showNewFolder = false
    @State private var showDeleteConfirm = false
    @State private var isDragTargeted = false

    /// Boundary discriminator for the loading/error/empty/content cross-fade.
    /// The `&& nodes.isEmpty` guards mirror the prior branch order so a
    /// refresh over existing content never flashes the spinner/error pane.
    private var browserState: DataState {
        if model.isLoading && model.nodes.isEmpty { return .loading }
        if model.hasError && model.nodes.isEmpty { return .error }
        if model.nodes.isEmpty { return .empty }
        return .content
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            storageToolbar
            Divider()

            // Breadcrumb
            breadcrumbBar
            Divider()

            // File list — cross-fade the loading/error/empty/content
            // BOUNDARY only. Refreshing an already-populated folder keeps the
            // state at `.content`, so the list updates instantly with no fade.
            DataStateContainer(state: browserState) {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } empty: {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Empty folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } error: {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } content: {
                FileListView(model: model)
            }

            // Status bar
            Divider()
            statusBar
        }
        #if os(macOS)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            Task {
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                        await model.uploadDroppedFile(fileURL)
                    }
                }
            }
            return true
        }
        .border(isDragTargeted ? Color.accentColor : Color.clear, width: 2)
        // Fade the drop-target border in/out instead of snapping it.
        .appAnimation(AppMotion.quick, value: isDragTargeted)
        #endif
        .task {
            await model.loadCurrentFolder()
        }
        .sheet(isPresented: $showNewFolder) {
            StorageNewFolderSheet(model: model, isPresented: $showNewFolder)
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
            .help("Navigate to parent folder")
            .accessibilityLabel("Go up one folder")

            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh folder contents")
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel("Refresh")

            Divider().frame(height: 16)

            #if os(macOS)
            Button { Task { await model.uploadWithPicker() } } label: {
                Label("Upload", systemImage: "arrow.up.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isUploading)
            .help("Upload a file to the current folder")
            .accessibilityLabel("Upload file")

            Button { Task { await model.downloadSelected() } } label: {
                Label("Download", systemImage: "arrow.down.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.selectedNode == nil || model.selectedNode?.isContainer == true)
            .help("Download the selected file")
            .accessibilityLabel("Download selected file")
            #endif

            Button { showNewFolder = true } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Create a new folder")
            .accessibilityLabel("New folder")

            Button { showDeleteConfirm = true } label: {
                Label("Delete", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.selectedNode == nil)
            .confirmationDialog("Delete \(model.selectedNode?.name ?? "")?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    Task { await model.deleteSelected() }
                }
            } message: {
                Text("This cannot be undone.")
            }

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

}
