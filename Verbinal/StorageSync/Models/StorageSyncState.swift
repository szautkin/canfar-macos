// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What this device knows of the person's VOSpace between syncs (plan 34
/// V): the manifest as last read, and each kind's items as last seen — how
/// a sync knows what changed without reading it. One per CADC account.
struct StorageSyncState: Codable, Equatable, Sendable {
    /// The manifest file's size and date when last read.
    var manifestStamp: StorageItem.Stamp?
    /// The manifest as last read, its bytes.
    var manifest: Data?
    var kinds: [String: KindState] = [:]
    var lastSync: Date?
    var lastFailure: String?
    /// How many automatic syncs in a row failed: the next waits longer.
    var failuresInARow = 0
    /// Paused by someone, until they resume it — kept, so a relaunch does
    /// not resume it (plan 40).
    var paused: Paused?

    struct Paused: Codable, Equatable, Sendable {
        /// person, assistant or app.
        var by: String
        var why: String?
        var at: Date
        /// Where it had got to: the kind, and how far.
        var kind: String?
        var done: Int?
        var total: Int?
    }

    struct KindState: Codable, Equatable, Sendable {
        var items: [String: StorageItem.Stamp] = [:]
        var bytes: Int64 = 0
        var lastSync: Date?
        var imported = 0
        var sent = 0
        var note: String?
        var failure: String?
        var memory: [String: String] = [:]
    }

    // MARK: - On disk

    static func file(for username: String, in directory: URL = productionDirectory) -> URL {
        let safe = username.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("state-\(safe).json")
    }

    static var productionDirectory: URL {
        AppSupport.directory.appendingPathComponent("Verbinal/StorageSync", isDirectory: true)
    }

    static func load(from file: URL) -> StorageSyncState {
        guard let data = try? Data(contentsOf: file) else { return StorageSyncState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(StorageSyncState.self, from: data)) ?? StorageSyncState()
    }

    func save(to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: file, options: .atomic)
    }
}
