// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Generic JSON-on-disk persistence for a `Codable` value type.
///
/// Moved from the host app into VerbinalKit because addons also need the same
/// disk-backed JSON pattern for their own stores (e.g. recent notebooks in Pi).
public struct DiskPersistence<T: Codable>: Sendable {
    /// Resolved file URL. `nil` if the Application Support directory is
    /// unavailable (e.g. sandbox failure). All methods become no-ops in that case.
    public let fileURL: URL?
    public let logger: Logger

    public init(subdirectory: String, fileName: String, logger: Logger) {
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
    public func read() -> T? {
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
    public func write(_ value: T) {
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
    public func delete() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
