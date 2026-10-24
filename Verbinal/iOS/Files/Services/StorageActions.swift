// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// What Your Storage does to the person's files (plan 48 F2): download one,
/// keep one on this device, delete, make a folder, upload (F3). Each change
/// goes through the storage client, which logs it as the Mac's do.
@Observable
@MainActor
final class StorageActions {
    /// Downloads and uploads under way, by storage path: how far, 0 to 1.
    private(set) var downloads: [String: Double] = [:]
    private(set) var uploads: [String: Double] = [:]
    var problem: String?

    let storage: VOSpaceBrowserService
    let username: String
    let library: DeviceLibrary

    init(storage: VOSpaceBrowserService, username: String, library: DeviceLibrary) {
        self.storage = storage
        self.username = username
        self.library = library
    }

    /// Downloads a storage file into this device's cache, with progress —
    /// for a file's page and for Your Storage alike.
    nonisolated static func download(_ file: FileRef, storage: VOSpaceBrowserService, username: String,
                                     into files: DeviceFiles,
                                     onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard case .storage(let path) = file.place else { throw CocoaError(.fileNoSuchFile) }
        let (temporary, _) = try await storage.downloadFile(
            username: username, path: path, expectedTotal: file.size ?? 0,
            onProgress: { done, total in
                guard total > 0 else { return }
                onProgress(Double(done) / Double(total))
            })
        return try files.cache.store(temporary, as: file)
    }

    /// How many items a folder holds, for the question before deleting it.
    func count(in folder: String) async -> Int? {
        try? await storage.listNodes(username: username, path: folder).count
    }

    /// Downloads `file` to this device, and with `keep` keeps it there.
    func download(_ file: FileRef, keep: Bool) async {
        guard case .storage(let path) = file.place, downloads[path] == nil else { return }
        let files = library.store
        downloads[path] = 0
        defer { downloads[path] = nil }
        do {
            let url: URL
            if let local = files.localCopy(of: file) {
                url = local
            } else {
                url = try await Self.download(file, storage: storage, username: username, into: files) { fraction in
                    Task { @MainActor in if self.downloads[path] != nil { self.downloads[path] = fraction } }
                }
            }
            if keep, let local = files.file(at: url), local.kind != .kept {
                try files.keep(local)
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        await library.reload()
    }

    /// Deletes a file, or a folder and all it holds, from storage.
    func delete(_ node: VOSpaceNode) async -> Bool {
        do {
            _ = try await storage.deleteNode(username: username, path: node.path, recursive: node.isContainer)
            problem = nil
            await library.forgetStorage(under: node.path)
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func createFolder(_ name: String, in parent: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FilesRules.isValidName(name) else { return false }
        do {
            try await storage.createFolder(username: username, parentPath: parent, folderName: name)
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// Uploads a file the person picked on this device into `folder`.
    func upload(_ url: URL, to folder: String) async -> Bool {
        let remote = folder.isEmpty ? url.lastPathComponent : folder + "/" + url.lastPathComponent
        uploads[remote] = 0
        defer { uploads[remote] = nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await storage.uploadFile(username: username, remotePath: remote, fileURL: url, onProgress: { done, total in
                guard total > 0 else { return }
                let fraction = Double(done) / Double(total)
                Task { @MainActor in if self.uploads[remote] != nil { self.uploads[remote] = fraction } }
            })
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}
