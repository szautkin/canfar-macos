// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit
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
    /// In-flight upload or download — drives the shared status-bar progress /
    /// cancel control. Nil when idle.
    var activeTransfer: StorageTransfer?
    /// In-flight transfer work — cancelled by the status-bar × control.
    @ObservationIgnored private var transferWork: Task<Void, Never>?
    var hasError = false
    var errorMessage = ""
    var statusMessage = ""

    /// True while any byte-streaming transfer is running (upload or download).
    var isTransferring: Bool { activeTransfer != nil }

    enum SortKey: String, CaseIterable { case name, size, date }
    enum SortOrder { case ascending, descending }
    var sortKey: SortKey = .name
    var sortOrder: SortOrder = .ascending

    var breadcrumbs: [BreadcrumbSegment] {
        BreadcrumbSegment.fromPath(currentPath)
    }

    var sortedNodes: [VOSpaceNode] {
        // Single stable pass: folders sort ahead of files, ties broken by the
        // active sort key. `sorted(by:)` is stable, so equal-priority nodes keep
        // their key order. Descending reverses the whole folders-then-files list
        // (folders are no longer guaranteed first when descending), matching the
        // prior two-filter behaviour exactly.
        let ascending = nodes.sorted { lhs, rhs in
            if lhs.isContainer != rhs.isContainer { return lhs.isContainer }
            switch sortKey {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                return (lhs.sizeBytes ?? 0) < (rhs.sizeBytes ?? 0)
            case .date:
                return (lhs.lastModified ?? .distantPast) < (rhs.lastModified ?? .distantPast)
            }
        }
        return sortOrder == .ascending ? ascending : ascending.reversed()
    }

    init(service: VOSpaceBrowserService, username: String) {
        self.service = service
        self.username = username
    }

    // MARK: - Navigation

    /// Navigate to `path`, committing the breadcrumb only after the listing
    /// succeeds. On failure the previous folder stays on screen and the
    /// error is surfaced in the status bar — previously we advanced the
    /// path first, so a 404/5xx left the user looking at the old listing
    /// under a wrong breadcrumb with no visible error (the center error
    /// pane only appears when `nodes` is empty).
    func navigateTo(_ path: String) async {
        selectedNode = nil
        await loadFolder(at: path, commitPath: true)
    }

    func goUp() async {
        guard !currentPath.isEmpty else { return }
        let parent: String
        if let lastSlash = currentPath.lastIndex(of: "/") {
            parent = String(currentPath[currentPath.startIndex..<lastSlash])
        } else {
            parent = ""
        }
        selectedNode = nil
        await loadFolder(at: parent, commitPath: true)
    }

    func refresh() async {
        await loadFolder(at: currentPath, commitPath: false)
    }

    func openNode(_ node: VOSpaceNode) async {
        if node.isContainer {
            let newPath = currentPath.isEmpty ? node.name : "\(currentPath)/\(node.name)"
            await navigateTo(newPath)
        }
    }

    // MARK: - Operations

    func loadCurrentFolder() async {
        await loadFolder(at: currentPath, commitPath: false)
    }

    /// Load the listing for `path`. When `commitPath` is true (navigation),
    /// `currentPath` updates only on success so a backend failure never
    /// orphans the breadcrumb. Refresh keeps the path and replaces `nodes`
    /// only on success so a flaky refresh doesn't blank the list.
    private func loadFolder(at path: String, commitPath: Bool) async {
        isLoading = true
        hasError = false
        errorMessage = ""
        do {
            let listed = try await service.listNodes(username: username, path: path)
            nodes = listed
            if commitPath { currentPath = path }
            let count = listed.count
            statusMessage = count == 1
                ? String(localized: "1 item")
                : String(localized: "\(count) items")
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
            // Keep the last successful listing + path; put the failure in
            // the status line so it's always visible (empty-state error
            // pane only covers the first-load / wiped-list case).
            statusMessage = error.localizedDescription
        }
        isLoading = false
    }

    func deleteSelected() async {
        guard let node = selectedNode else { return }
        let path = currentPath.isEmpty ? node.name : "\(currentPath)/\(node.name)"
        do {
            try await service.deleteNode(username: username, path: path)
            selectedNode = nil
            statusMessage = String(localized: "Deleted \(node.name)")
            await loadCurrentFolder()
        } catch {
            reportError(error.localizedDescription)
        }
    }

    func createFolder(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            reportError(String(localized: "Invalid folder name"))
            return
        }
        do {
            try await service.createFolder(username: username, parentPath: currentPath, folderName: trimmed)
            statusMessage = String(localized: "Created folder \(trimmed)")
            await loadCurrentFolder()
        } catch {
            reportError(error.localizedDescription)
        }
    }

    /// Surface a failure in both the center error pane (when the list is
    /// empty) and the always-visible status bar.
    private func reportError(_ message: String) {
        hasError = true
        errorMessage = message
        statusMessage = message
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

        await performUpload(fileURL: fileURL)
    }

    func downloadSelected() async {
        guard let node = selectedNode, !node.isContainer else { return }
        let path = currentPath.isEmpty ? node.name : "\(currentPath)/\(node.name)"
        let filename = node.name

        // Destination first — Mac convention. Progress/cancel only start
        // after the user commits a path (canceling the panel is a no-op).
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.title = "Save File"
        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        let outcome = await performDownload(
            remotePath: path,
            fileName: filename,
            expectedTotal: node.sizeBytes ?? 0
        )
        guard case .success(let tempURL, _) = outcome else { return }

        let didStart = saveURL.startAccessingSecurityScopedResource()
        defer { if didStart { saveURL.stopAccessingSecurityScopedResource() } }
        do {
            if FileManager.default.fileExists(atPath: saveURL.path) {
                try FileManager.default.removeItem(at: saveURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: saveURL)
            statusMessage = String(localized: "Saved \(filename)")
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            reportError(error.localizedDescription)
        }
    }

    /// Download a .fits file to temp and open in FITS Viewer.
    func openInFITSViewer(_ node: VOSpaceNode) async {
        let path = currentPath.isEmpty ? node.name : "\(currentPath)/\(node.name)"
        let outcome = await performDownload(
            remotePath: path,
            fileName: node.name,
            expectedTotal: node.sizeBytes ?? 0
        )
        guard case .success(let tempURL, _) = outcome else { return }
        statusMessage = ""
        onOpenFile?(tempURL)
    }

    /// Upload a file dropped from Finder.
    func uploadDroppedFile(_ fileURL: URL) async {
        await performUpload(fileURL: fileURL)
    }

    /// Cancel the in-flight upload or download. Safe no-op when idle.
    func cancelTransfer() {
        transferWork?.cancel()
    }

    private enum DownloadOutcome {
        case success(tempURL: URL, filename: String)
        case cancelled
        case failed
    }

    private func performUpload(fileURL: URL) async {
        let fileName = fileURL.lastPathComponent
        let remotePath = currentPath.isEmpty ? fileName : "\(currentPath)/\(fileName)"
        // Open-panel / drag-drop URLs need the security scope before
        // `resourceValues` will return a size.
        let fileSize = Self.securedFileByteCount(at: fileURL)

        await runTransfer(
            StorageTransfer(
                kind: .upload,
                fileName: fileName,
                fraction: fileSize > 0 ? 0 : nil,
                bytesTransferred: 0,
                bytesTotal: fileSize
            )
        ) { [service, username] onProgress in
            try await service.uploadFile(
                username: username,
                remotePath: remotePath,
                fileURL: fileURL,
                onProgress: onProgress
            )
            return ()
        } onSuccess: { _ in
            await self.loadCurrentFolder()
        }
    }

    private func performDownload(
        remotePath: String,
        fileName: String,
        expectedTotal: Int64
    ) async -> DownloadOutcome {
        var result: DownloadOutcome = .failed
        await runTransfer(
            StorageTransfer(
                kind: .download,
                fileName: fileName,
                fraction: expectedTotal > 0 ? 0 : nil,
                bytesTransferred: 0,
                bytesTotal: expectedTotal
            )
        ) { [service, username] onProgress in
            try await service.downloadFile(
                username: username,
                path: remotePath,
                expectedTotal: expectedTotal,
                onProgress: onProgress
            )
        } onSuccess: { pair in
            result = .success(tempURL: pair.tempURL, filename: pair.filename)
        } onCancelled: {
            result = .cancelled
        } onFailed: {
            result = .failed
        }
        return result
    }

    /// Single pipeline for upload and download: one active transfer, one
    /// cancel handle, one throttled progress updater, one status-bar contract.
    private func runTransfer<Result>(
        _ seed: StorageTransfer,
        work: @escaping @Sendable (
            _ onProgress: @escaping NetworkClient.TransferProgressHandler
        ) async throws -> Result,
        onSuccess: @escaping @MainActor (Result) async -> Void,
        onCancelled: (@MainActor () -> Void)? = nil,
        onFailed: (@MainActor () -> Void)? = nil
    ) async {
        transferWork?.cancel()

        hasError = false
        activeTransfer = seed
        statusMessage = seed.bytesTotal > 0
            ? seed.progressiveStatus(bytesTransferred: 0, bytesTotal: seed.bytesTotal)
            : seed.indeterminateStatus()

        let throttle = TransferProgressThrottle()
        let workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeTransfer = nil
                self.transferWork = nil
            }
            do {
                let result = try await work { [weak self] transferred, total in
                    guard throttle.shouldPublish(transferred: transferred, total: total) else { return }
                    // Progress arrives off-main (URLSession / KVO). Hop once;
                    // don't touch `self` on the callback queue.
                    Task { @MainActor [weak self] in
                        self?.applyTransferProgress(transferred: transferred, total: total)
                    }
                }
                if Task.isCancelled {
                    onCancelled?()
                    return
                }
                if var transfer = self.activeTransfer {
                    transfer.fraction = 1
                    transfer.bytesTransferred = max(transfer.bytesTotal, transfer.bytesTransferred)
                    self.activeTransfer = transfer
                    self.statusMessage = transfer.completedStatus()
                }
                await onSuccess(result)
            } catch is CancellationError {
                self.statusMessage = seed.cancelledStatus
                self.hasError = false
                self.errorMessage = ""
                onCancelled?()
            } catch {
                self.reportError(error.localizedDescription)
                onFailed?()
            }
        }
        transferWork = workTask
        await workTask.value
    }

    private func applyTransferProgress(transferred: Int64, total: Int64) {
        guard var transfer = activeTransfer else { return }
        // Prefer the latest server/listing total, but never drop a known
        // seed (listing `#length`) when a callback omits Content-Length.
        let effectiveTotal = max(total, transfer.bytesTotal)
        guard effectiveTotal > 0 || transferred > 0 else { return }
        transfer.bytesTransferred = transferred
        if effectiveTotal > 0 {
            transfer.bytesTotal = effectiveTotal
            transfer.fraction = min(1, Double(transferred) / Double(effectiveTotal))
        } else {
            // Unknown size — keep the spinner; don't pin the bar at 100%.
            transfer.fraction = nil
        }
        activeTransfer = transfer
        statusMessage = transfer.progressiveStatus(
            bytesTransferred: transferred,
            bytesTotal: transfer.bytesTotal
        )
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

#if os(macOS)
extension StorageBrowserModel {
    /// Byte count for a user-picked file, taking the security-scoped
    /// bookmark briefly so sandbox-restricted URLs still resolve a size.
    fileprivate static func securedFileByteCount(at url: URL) -> Int64 {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(size)
        }
        if let n = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber {
            return n.int64Value
        }
        return 0
    }
}
#endif
