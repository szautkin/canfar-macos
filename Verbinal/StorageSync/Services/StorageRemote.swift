// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// An item of a folder in VOSpace, as a listing gives it.
struct StorageItem: Codable, Equatable, Sendable {
    let name: String
    let size: Int64?
    let modified: Date?
    let isFolder: Bool

    /// What a sync compares to know an item changed without reading it.
    var stamp: Stamp { Stamp(size: size, modified: modified) }

    struct Stamp: Codable, Equatable, Sendable {
        let size: Int64?
        let modified: Date?

        /// The same item: the same size, and dated within the same second.
        /// VOSpace gives milliseconds and the state file keeps whole seconds;
        /// compared exactly, every item looked changed after each relaunch —
        /// 288 package lists and 474 runs fetched again at every launch
        /// (2026-10-16). Two writes in one second at one size are taken as one.
        static func == (a: Stamp, b: Stamp) -> Bool {
            guard a.size == b.size else { return false }
            switch (a.modified, b.modified) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x.timeIntervalSince(y)) < 1
            default: return false
            }
        }
    }
}

/// What the sync needs of the person's VOSpace (plan 34 V): paths from the
/// home. `VOSpaceBrowserService` stays the one owner of the wire; tests
/// give the sync a VOSpace of their own (dependency inversion).
protocol StorageRemote: Sendable {
    /// A folder's items; nil when the folder is not there.
    func list(_ folder: String) async throws -> [StorageItem]?
    func read(_ path: String) async throws -> Data
    /// Writes `data` at `path`, making its folders first.
    func write(_ data: Data, to path: String) async throws
    /// Whether anyone may read the folder.
    func isPublic(_ folder: String) async throws -> Bool
    /// Whether the account has a storage home: only CANFAR's accounts do,
    /// not every CADC one.
    func hasHome() async throws -> Bool
}

/// The sizes a sync wrote, by path (plan 44 A2).
actor WrittenSizes {
    private(set) var sizes: [String: Int64] = [:]
    func wrote(_ size: Int, at path: String) { sizes[path] = Int64(size) }
}

/// A remote that notes what is written through it, so a sync knows its
/// own writes from another device's.
struct WriteRecordingRemote: StorageRemote {
    let base: any StorageRemote
    let written: WrittenSizes

    func list(_ folder: String) async throws -> [StorageItem]? { try await base.list(folder) }
    func read(_ path: String) async throws -> Data { try await base.read(path) }
    func write(_ data: Data, to path: String) async throws {
        try await base.write(data, to: path)
        await written.wrote(data.count, at: path)
    }
    func isPublic(_ folder: String) async throws -> Bool { try await base.isPublic(folder) }
    func hasHome() async throws -> Bool { try await base.hasHome() }
}

/// The person's VOSpace, through the Storage client.
struct VOSpaceStorageRemote: StorageRemote {
    let vospace: VOSpaceBrowserService
    let username: String

    func list(_ folder: String) async throws -> [StorageItem]? {
        do {
            return try await vospace.listNodes(username: username, path: folder, limit: 10_000).map {
                StorageItem(name: $0.name, size: $0.sizeBytes, modified: $0.lastModified, isFolder: $0.isContainer)
            }
        } catch let error as NetworkError {
            if case .httpError(404, _) = error { return nil }
            throw error
        }
    }

    func read(_ path: String) async throws -> Data {
        let (url, _) = try await vospace.downloadFile(username: username, path: path)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to path: String) async throws {
        let parts = path.split(separator: "/").map(String.init)
        try await vospace.ensureFolder(username: username, path: parts.dropLast().joined(separator: "/"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("verbinal-sync-\(UUID().uuidString)-\(parts.last ?? "item")")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await vospace.uploadFile(username: username, remotePath: path, fileURL: file)
    }

    func hasHome() async throws -> Bool {
        do {
            return try await vospace.node(username: username, path: "") != nil
        } catch let error as NetworkError {
            if case .httpError(403, _) = error { return false }
            throw error
        }
    }

    func isPublic(_ folder: String) async throws -> Bool {
        try await vospace.node(username: username, path: folder)?.isPublic ?? false
    }
}
