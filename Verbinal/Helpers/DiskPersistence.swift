// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Generic JSON-on-disk persistence for a `Codable` value type.
///
/// Consolidates the identical `fileURL` / `readFromDisk` / `writeToDisk` pattern
/// that was duplicated across ~9 stores in the app (observations, notes, portal
/// settings + cache, recent launches, recent searches, saved queries, bookmarks,
/// recent notebooks).
///
/// Design choices:
/// - **Struct** (not class, not property wrapper) — no identity, zero retain-cycle
///   surface area, composes cleanly with `@Observable` classes.
/// - **Sendable + nonisolated** — callable from any actor. Stores own their
///   `@Observable` state under their actor isolation; this type just does I/O.
/// - **One-time directory creation in `init`** — avoids the per-access
///   `createDirectory` syscall that the previous inline implementations had.
/// - **Standardized JSON format** — `.iso8601` dates, `.prettyPrinted`,
///   `.sortedKeys`, `.atomic` writes. Key order change is harmless because all
///   JSON decoders are order-agnostic.
/// - **Per-store logger** — each store passes its own `Logger` so log categories
///   remain meaningful after consolidation.
///
/// Usage:
/// ```swift
/// private let persistence = DiskPersistence<[SavedQuery]>(
///     subdirectory: "Verbinal",
///     fileName: "saved_queries.json",
///     logger: Self.logger
/// )
/// // read
/// queries = persistence.read() ?? []
/// // write
/// persistence.write(queries)
/// ```
struct DiskPersistence<T: Codable>: Sendable {
    /// Resolved file URL. `nil` if the Application Support directory is
    /// unavailable (e.g. sandbox failure). All methods become no-ops in that case.
    let fileURL: URL?
    let logger: Logger

    init(subdirectory: String, fileName: String, logger: Logger) {
        self.logger = logger
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        guard let dir = appSupport?.appendingPathComponent(subdirectory, isDirectory: true) else {
            self.fileURL = nil
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent(fileName)
        } catch {
            logger.error("Directory creation failed for \(subdirectory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.fileURL = nil
        }
    }

    /// Decode and return the persisted value, or `nil` if the file does not
    /// exist or cannot be decoded. Decode failures are logged at `.warning`.
    func read() -> T? {
        guard let fileURL else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.warning("Read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Atomically encode and write the value to disk. Encode/write failures are
    /// logged at `.error`. No-op if the directory is unavailable.
    func write(_ value: T) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove the persisted file (e.g. on logout). No-op if absent.
    func delete() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
