// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Research's files in the person's VOSpace (the person's request,
/// 2026-10-09), through the Storage client: never over another file.
struct VOSpaceResearchStorage: ResearchStorage {
    let vospace: VOSpaceBrowserService
    let username: String

    /// A different file of that name is there already.
    struct Taken: LocalizedError {
        let path: String
        var errorDescription: String? {
            String(localized: "A different file is in your storage at \(path) already: nothing was written over it.")
        }
    }

    func send(_ file: URL, toFolder folder: String) async throws -> String {
        let path = try ResultUpload.remotePath(for: file, in: folder, username: username)
        if let there = try await vospace.node(username: username, path: path) {
            // The same file, sent before (by Results, or another Mac): taken as this one.
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
            guard let size, there.sizeBytes == size else { throw Taken(path: path) }
            return path
        }
        return try await ResultUpload(vospace: vospace, username: username).upload(file, to: path)
    }

    func fetch(_ path: String) async throws -> URL {
        try await vospace.downloadFile(username: username, path: path).tempURL
    }

    func remove(_ path: String) async throws {
        _ = try await vospace.deleteNode(username: username, path: path)
    }

    func size(_ path: String) async throws -> Int64? {
        guard let node = try await vospace.node(username: username, path: path) else { return nil }
        return node.sizeBytes ?? 0
    }
}
