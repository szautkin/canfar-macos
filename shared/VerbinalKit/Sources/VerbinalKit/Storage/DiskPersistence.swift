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
    /// The on-disk schema version this store writes and the highest it can read.
    /// Bump in a store when its persisted type changes in a way an older build
    /// could not safely read. Files written with a higher version are refused
    /// (not clobbered) — important once data syncs across devices/accounts.
    public let schemaVersion: Int

    /// Versioned wrapper written to disk: `{ "schemaVersion": N, "value": <T> }`.
    /// Reading falls back to a bare `T` for files written before versioning.
    private struct Envelope: Codable {
        let schemaVersion: Int
        let value: T
    }

    public init(subdirectory: String, fileName: String, logger: Logger, schemaVersion: Int = 1) {
        self.logger = logger
        self.schemaVersion = schemaVersion
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

    /// Outcome of a read that distinguishes "no file yet" from "file present but
    /// unreadable" — so callers can tell a fresh install from data corruption
    /// instead of both collapsing to an empty store.
    public enum ReadOutcome {
        /// No file on disk (fresh install / never written / quarantined away).
        case missing
        /// Successfully decoded value.
        case value(T)
        /// File existed but could not be decoded; it has been quarantined
        /// (renamed) to preserve its bytes, with the new location if the move
        /// succeeded.
        case corrupt(quarantinedTo: URL?)
        /// File was written by a newer schema version than this build supports.
        /// Left untouched (NOT quarantined) so a newer device's data survives.
        case unsupported(foundVersion: Int)
    }

    /// Read, distinguishing missing vs corrupt. On corruption the unreadable file
    /// is *quarantined* (renamed to a `.corrupt-…` sibling) rather than left in
    /// place: its bytes survive for recovery, and the next read starts clean
    /// instead of failing forever. Logged at `.error`.
    public func readResult() -> ReadOutcome {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logger.error("Read failed \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public) — quarantining")
            return .corrupt(quarantinedTo: quarantineCorruptFile(at: fileURL))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Preferred path: a versioned envelope.
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            if envelope.schemaVersion > schemaVersion {
                logger.error("Store \(fileURL.lastPathComponent, privacy: .public) is schema v\(envelope.schemaVersion), newer than supported v\(self.schemaVersion) — not loading to avoid clobbering newer data")
                return .unsupported(foundVersion: envelope.schemaVersion)
            }
            // Older or equal: additive field changes are absorbed by Codable's
            // optional synthesis; explicit per-version migrations can be layered
            // in later if a non-additive change is needed.
            return .value(envelope.value)
        }

        // Backward compatibility: a bare value written before versioning (treated
        // as v1). Going forward this is re-saved as an envelope on the next write.
        if let legacy = try? decoder.decode(T.self, from: data) {
            return .value(legacy)
        }

        logger.error("Corrupt store \(fileURL.lastPathComponent, privacy: .public): not a valid envelope or legacy value — quarantining instead of silently discarding")
        return .corrupt(quarantinedTo: quarantineCorruptFile(at: fileURL))
    }

    /// Decode and return the persisted value, or `nil` if the file is missing or
    /// corrupt. Corrupt files are quarantined as a side-effect (see
    /// ``readResult()``); callers that need to surface corruption to the user
    /// should call ``readResult()`` directly.
    public func read() -> T? {
        if case .value(let value) = readResult() { return value }
        return nil
    }

    /// Move an unreadable file aside so its bytes are preserved for recovery and
    /// the next read starts clean. Best-effort; returns the new location on success.
    private func quarantineCorruptFile(at fileURL: URL) -> URL? {
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent
        var target = dir.appendingPathComponent("\(base).corrupt-\(Int(Date().timeIntervalSince1970))")
        if FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base).corrupt-\(UUID().uuidString)")
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            logger.error("Quarantined corrupt store to \(target.lastPathComponent, privacy: .public)")
            return target
        } catch {
            logger.error("Quarantine move failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Atomically encode and write the value to disk. Returns `true` on success,
    /// `false` if the directory is unavailable or the encode/write failed (logged
    /// at `.error`). The result is `@discardableResult` so existing call sites are
    /// unaffected, but callers that must know whether the save landed (to surface
    /// a "save failed" affordance) can check it.
    @discardableResult
    public func write(_ value: T) -> Bool {
        guard let fileURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: schemaVersion, value: value))
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Remove the persisted file (e.g. on logout). No-op if absent.
    public func delete() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
