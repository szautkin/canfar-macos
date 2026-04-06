// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// Manages VOSpace file browser state: navigation, listing, sorting, operations.
@Observable
@MainActor
final class StorageBrowserModel {
    private let service: VOSpaceBrowserService
    private let username: String

    /// Callback to open a file in another module (e.g. FITS Viewer).
    var onOpenFile: ((URL) -> Void)?

    var nodes: [VOSpaceNode] = []
    var currentPath = ""
    var selectedNode: VOSpaceNode?
    var isLoading = false
    var isUploading = false
    var hasError = false
    var errorMessage = ""
    var statusMessage = ""

    enum SortKey: String, CaseIterable { case name, size, date }
    enum SortOrder { case ascending, descending }
    var sortKey: SortKey = .name
    var sortOrder: SortOrder = .ascending

    var breadcrumbs: [BreadcrumbSegment] {
        BreadcrumbSegment.fromPath(currentPath)
    }

    var sortedNodes: [VOSpaceNode] {
        let sorted: [VOSpaceNode]
        switch sortKey {
        case .name:
            sorted = nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            sorted = nodes.sorted { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }
        case .date:
            sorted = nodes.sorted { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
        }

        // Folders first, then apply sort order
        let folders = sorted.filter(\.isContainer)
        let files = sorted.filter { !$0.isContainer }
        let ordered = sortOrder == .ascending ? (folders + files) : (folders + files).reversed()
        return Array(ordered)
    }

    init(service: VOSpaceBrowserService, username: String) {
        self.service = service
        self.username = username
    }

    // MARK: - Navigation

    func navigateTo(_ path: String) async {
        currentPath = path
        selectedNode = nil
        await loadCurrentFolder()
    }

    func goUp() async {
        guard !currentPath.isEmpty else { return }
        if let lastSlash = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[currentPath.startIndex..<lastSlash])
        } else {
            currentPath = ""
        }
        selectedNode = nil
        await loadCurrentFolder()
    }

    func refresh() async {
        await loadCurrentFolder()
    }

    func openNode(_ node: VOSpaceNode) async {
        if node.isContainer {
            let newPath = currentPath.isEmpty ? node.name : "\(currentPath)/\(node.name)"
            await navigateTo(newPath)
        }
    }

    // MARK: - Operations

    func loadCurrentFolder() async {
        isLoading = true
        hasError = false
        do {
            nodes = try await service.listNodes(username: username, path: currentPath)
            statusMessage = "\(nodes.count) items"
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func deleteSelected() async {
        guard let node = selectedNode else { return }
        let path = currentPath.isEmpty ? node.name : "\(currentPath)/\(node.name)"
        do {
            try await service.deleteNode(username: username, path: path)
            selectedNode = nil
            await loadCurrentFolder()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            hasError = true
            errorMessage = "Invalid folder name"
            return
        }
        do {
            try await service.createFolder(username: username, parentPath: currentPath, folderName: trimmed)
            await loadCurrentFolder()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    func uploadWithPicker() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Upload File"

        let response = panel.runModal()
        guard response == .OK, let fileURL = panel.url else { return }

        let fileName = fileURL.lastPathComponent
        let remotePath = currentPath.isEmpty ? fileName : "\(currentPath)/\(fileName)"

        isUploading = true
        statusMessage = "Uploading \(fileName)..."
        do {
            try await service.uploadFile(username: username, remotePath: remotePath, fileURL: fileURL)
            statusMessage = "Uploaded \(fileName)"
            await loadCurrentFolder()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
        isUploading = false
    }

    func downloadSelected() async {
        guard let node = selectedNode, !node.isContainer else { return }
        let path = currentPath.isEmpty ? node.name : "\(currentPath)/\(node.name)"

        statusMessage = "Downloading \(node.name)..."
        do {
            let (tempURL, filename) = try await service.downloadFile(username: username, path: path)

            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.canCreateDirectories = true
            panel.title = "Save File"

            let response = panel.runModal()
            if response == .OK, let saveURL = panel.url {
                if FileManager.default.fileExists(atPath: saveURL.path) {
                    try FileManager.default.removeItem(at: saveURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: saveURL)
                statusMessage = "Saved \(filename)"
            } else {
                try? FileManager.default.removeItem(at: tempURL)
                statusMessage = ""
            }
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
    }
    /// Download a .fits file to temp and open in FITS Viewer.
    func openInFITSViewer(_ node: VOSpaceNode) async {
        let path = currentPath.isEmpty ? node.name : "\(currentPath)/\(node.name)"
        statusMessage = "Downloading \(node.name) for viewing..."
        do {
            let (tempURL, _) = try await service.downloadFile(username: username, path: path)
            statusMessage = ""
            onOpenFile?(tempURL)
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func toggleSort(_ key: SortKey) {
        if sortKey == key {
            sortOrder = sortOrder == .ascending ? .descending : .ascending
        } else {
            sortKey = key
            sortOrder = .ascending
        }
    }

    /// Full VOSpace URI for clipboard.
    func vospaceURI(for node: VOSpaceNode) -> String {
        let path = currentPath.isEmpty ? "\(username)/\(node.name)" : "\(username)/\(currentPath)/\(node.name)"
        return "vos://cadc.nrc.ca~arc/home/\(path)"
    }
}
