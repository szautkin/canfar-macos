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
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } empty: {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Empty folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Upload a file or create a new folder to get started.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
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
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
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
        .uiPresented("New Folder", .sheet, isPresented: $showNewFolder)
        .sheet(isPresented: $showNewFolder) {
            StorageNewFolderSheet(model: model, isPresented: $showNewFolder)
        }
    }

    // MARK: - Toolbar

    private var storageToolbar: some View {
        // Horizontal scroll so Delete isn't clipped when the Storage
        // pane is narrow (Windows keeps the same actions icon+label;
        // we match that order: New / Upload / Download / Delete).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { Task { await model.goUp() } } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(model.currentPath.isEmpty)
                .help("Navigate to parent folder")
                .accessibilityLabel("Go up one folder")
                .pointable("storage.up")

                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh folder contents")
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh")
                .pointable("storage.refresh")

                Divider().frame(height: 16)

                Button { showNewFolder = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Create a new folder")
                .accessibilityLabel("New folder")
                .pointable("storage.newFolder", opens: "New Folder")

                #if os(macOS)
                Button { Task { await model.uploadWithPicker() } } label: {
                    Label("Upload", systemImage: "arrow.up.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy)
                .help("Upload a file to the current folder")
                .accessibilityLabel("Upload file")
                .pointable("storage.upload", opens: "Upload File")

                Button { Task { await model.downloadSelected() } } label: {
                    Label("Download", systemImage: "arrow.down.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy
                          || model.selectedNode == nil
                          || model.selectedNode?.isContainer == true)
                .help(model.selectedNode == nil
                      ? "Select a file to download"
                      : "Download the selected file")
                .accessibilityLabel("Download selected file")
                .pointable("storage.download", opens: "Save File")
                #endif

                Button { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.selectedNode == nil || model.isBusy)
                .keyboardShortcut(.delete, modifiers: [.command])
                .help(model.selectedNode == nil
                      ? "Select a file or folder to delete"
                      : "Delete the selected item")
                .accessibilityLabel("Delete selected item")
                .pointable("storage.delete")
                .uiPresented("Delete the Selected?", .confirmation, isPresented: $showDeleteConfirm)
                .confirmationDialog(
                    "Delete \(model.selectedNode?.name ?? "")?",
                    isPresented: $showDeleteConfirm
                ) {
                    Button("Delete", role: .destructive) {
                        Task { await model.deleteSelected() }
                    }
                } message: {
                    Text(model.selectedNode?.isContainer == true
                         ? "This folder and its contents will be permanently deleted."
                         : "This cannot be undone.")
                }

                if model.isBusy {
                    // Fixed 16×16 frame — `scaleEffect` would still reserve
                    // the default ProgressView layout size and jump the row.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
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
        // Always-visible feedback strip. Backend failures used to set
        // `hasError` but only the center pane (visible when the list is
        // empty) rendered them — a 404 while browsing looked like nothing
        // happened. Errors now tint the status line orange so they're
        // readable over a populated listing too.
        HStack(spacing: 6) {
            if model.hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(model.errorMessage.isEmpty ? model.statusMessage : model.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Spacer()
                Button("Dismiss") {
                    model.hasError = false
                    model.errorMessage = ""
                    model.statusMessage = StorageBrowserModel.itemCount(model.nodes.count)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let transfer = model.activeTransfer {
                // Shared upload/download chrome — cancel sits immediately
                // after the bar (not after a Spacer on the trailing edge).
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                        .controlSize(.small)
                        .accessibilityValue(Text("\(Int(fraction * 100)) percent"))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
                Button {
                    model.cancelTransfer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(transfer.cancelAccessibilityLabel)
                .accessibilityLabel(transfer.cancelAccessibilityLabel)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            } else {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(model.hasError ? Color.orange.opacity(0.08) : Color.clear)
        .accessibilityLabel(model.hasError
                            ? "Error: \(model.errorMessage)"
                            : model.statusMessage)
    }

}
