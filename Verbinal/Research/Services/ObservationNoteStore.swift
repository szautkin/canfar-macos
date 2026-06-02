// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import GRDB
import VerbinalKit

/// Persists per-observation notes in the GRDB database, keyed by publisherID so a
/// note survives file deletion (notes live on the *observation*, not the local
/// file copy). Phase 1 of the storage-DB migration (DB_DESIGN v2).
///
/// Concurrency: an `@MainActor @Observable` facade. Reads are synchronous off the
/// in-memory `notes` mirror; writes are per-row upserts to the DB (fast, no
/// whole-file re-encode). External-content FTS5 over the note text + tags powers
/// ``searchPublisherIDs(matching:)`` — the "find a download by what you wrote
/// about it" feature.
@Observable
@MainActor
final class ObservationNoteStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ObservationNoteStore")

    private let db: AppDatabase
    private let deviceID: String

    /// In-memory mirror of LIVE (non-deleted) notes, keyed by publisherID.
    private(set) var notes: [String: ObservationNote] = [:]

    /// The production legacy JSON store the one-shot importer migrates from.
    static let productionLegacyNotesStore = DiskPersistence<[String: ObservationNote]>(
        subdirectory: "Verbinal", fileName: "observation_notes.json", logger: logger
    )

    /// - Parameter legacyNotesSource: the pre-DB JSON to one-shot import (once,
    ///   guarded by a `meta` flag). Defaults to the production file. Tests pass
    ///   `nil` to skip migration, or a seeded temp store to exercise the importer.
    init(database: AppDatabase = .shared,
         legacyNotesSource: DiskPersistence<[String: ObservationNote]>? = ObservationNoteStore.productionLegacyNotesStore) {
        self.db = database
        self.deviceID = Self.installDeviceID()
        if let legacyNotesSource {
            migrateLegacyJSONIfNeeded(from: legacyNotesSource)
        }
        reload()
    }

    // MARK: - Read

    func note(for publisherID: String) -> ObservationNote? { notes[publisherID] }

    /// Reload the live-notes mirror from the DB.
    func reload() {
        do {
            let rows = try db.reader.read { d in
                try Row.fetchAll(d, sql: "SELECT * FROM note WHERE deletedAt IS NULL")
            }
            notes = Dictionary(uniqueKeysWithValues: rows.map { row in
                let n = Self.note(from: row)
                return (n.publisherID, n)
            })
        } catch {
            Self.logger.error("Reload failed: \(error.localizedDescription, privacy: .public)")
            notes = [:]
        }
    }

    /// PublisherIDs of LIVE notes whose text or tags match `query` (FTS5).
    func searchPublisherIDs(matching query: String) -> [String] {
        let pattern = Self.ftsPrefixPattern(query)
        guard !pattern.isEmpty else { return [] }
        do {
            return try db.reader.read { d in
                try String.fetchAll(d, sql: """
                    SELECT note.publisherID FROM noteSearch
                    JOIN note ON note.rowid = noteSearch.rowid
                    WHERE noteSearch MATCH ? AND note.deletedAt IS NULL
                    """, arguments: [pattern])
            }
        } catch {
            Self.logger.error("Search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Write

    /// Save a note. Empty notes are removed entirely (no blank rows).
    func save(_ note: ObservationNote) {
        if note.isEmpty {
            remove(publisherID: note.publisherID)
            return
        }
        var updated = note
        updated.modifiedAt = Date()
        do {
            try db.writer.write { [deviceID] d in try Self.upsert(updated, deviceID: deviceID, in: d) }
            notes[updated.publisherID] = updated
        } catch {
            Self.logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Soft-delete the note (tombstone) so the deletion can sync later; drops it
    /// from the live mirror and the FTS index.
    func remove(publisherID: String) {
        guard notes[publisherID] != nil else { return }
        let now = Self.iso(Date())
        do {
            try db.writer.write { [deviceID] d in
                try d.execute(sql: """
                    UPDATE note
                    SET deletedAt = ?, updatedAt = ?, version = version + 1, lastWriterDeviceID = ?,
                        text = '', tags = ''
                    WHERE publisherID = ? AND deletedAt IS NULL
                    """, arguments: [now, now, deviceID, publisherID])
            }
            notes[publisherID] = nil
        } catch {
            Self.logger.error("Remove failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Row <-> model

    private static func note(from row: Row) -> ObservationNote {
        ObservationNote(
            publisherID: row["publisherID"],
            text: row["text"] ?? "",
            rating: row["rating"] ?? 0,
            tags: parseTags(row["tags"]),
            createdAt: parseISO(row["createdAt"]) ?? Date(),
            modifiedAt: parseISO(row["modifiedAt"]) ?? Date(),
            agentAttribution: decodeAttribution(row["agentAttribution"])
        )
    }

    private static func upsert(_ n: ObservationNote, deviceID: String, in db: Database) throws {
        let now = iso(Date())
        try db.execute(sql: """
            INSERT INTO note
                (uuid, publisherID, text, rating, tags, agentAttribution,
                 createdAt, modifiedAt, updatedAt, version, deletedAt, lastWriterDeviceID)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, NULL, ?)
            ON CONFLICT(publisherID) DO UPDATE SET
                text = excluded.text,
                rating = excluded.rating,
                tags = excluded.tags,
                agentAttribution = excluded.agentAttribution,
                modifiedAt = excluded.modifiedAt,
                updatedAt = excluded.updatedAt,
                version = note.version + 1,
                deletedAt = NULL,
                lastWriterDeviceID = excluded.lastWriterDeviceID
            """, arguments: [
                UUID().uuidString, n.publisherID, n.text, n.rating, joinTags(n.tags),
                encodeAttribution(n.agentAttribution),
                iso(n.createdAt), iso(n.modifiedAt), now, deviceID
            ])
    }

    // MARK: - Helpers

    private static let isoFormatter = ISO8601DateFormatter()   // [.withInternetDateTime], no fractional

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    private static func parseISO(_ s: String?) -> Date? { s.flatMap { isoFormatter.date(from: $0) } }

    private static func joinTags(_ tags: [String]) -> String { tags.joined(separator: ", ") }
    private static func parseTags(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func encodeAttribution(_ a: AgentAttribution?) -> String? {
        guard let a, let data = try? JSONEncoder().encode(a) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func decodeAttribution(_ s: String?) -> AgentAttribution? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentAttribution.self, from: data)
    }

    /// Turn free user text into a safe FTS5 prefix query: each whitespace-split
    /// token becomes a quoted prefix term, AND-ed. Quoting avoids FTS operator
    /// injection from user input (e.g. a stray `"` or `*`).
    private static func ftsPrefixPattern(_ query: String) -> String {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { token -> String in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }

    /// Stable per-install device id (for `lastWriterDeviceID`, used by future sync).
    private static func installDeviceID() -> String {
        let key = "verbinal.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    // MARK: - One-shot JSON → DB migration (Phase 1-D)

    private func migrateLegacyJSONIfNeeded(from legacy: DiskPersistence<[String: ObservationNote]>) {
        let flagKey = "notesMigrated"
        do {
            let already = try db.reader.read { d in
                try Bool.fetchOne(d, sql: "SELECT 1 FROM meta WHERE key = ?", arguments: [flagKey]) ?? false
            }
            if already { return }
        } catch {
            Self.logger.error("Migration flag check failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        switch legacy.readResult() {
        case .unsupported(let v):
            // Newer build's data — do NOT migrate or set the flag; leave the JSON
            // intact so a future build can read it. (DB_DESIGN v2 §5.)
            Self.logger.error("Legacy notes file is schema v\(v), newer than supported — aborting notes migration")
            return
        case .missing, .corrupt:
            // Nothing to import (corrupt already quarantined by S01). Mark migrated.
            markMigrated(flagKey)
        case .value(let legacyNotes):
            do {
                try db.writer.write { [deviceID] d in
                    for (_, n) in legacyNotes where !n.isEmpty {
                        try Self.upsert(n, deviceID: deviceID, in: d)
                    }
                    try d.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, '1')",
                                  arguments: [flagKey])
                }
                let imported = legacyNotes.values.filter { !$0.isEmpty }.count
                Self.logger.info("Migrated \(imported) notes JSON→DB")
                // Move the JSON aside as a backup (never delete this iteration).
                if let url = legacy.fileURL, FileManager.default.fileExists(atPath: url.path) {
                    let backup = url.appendingPathExtension("migrated")
                    try? FileManager.default.removeItem(at: backup)
                    try? FileManager.default.moveItem(at: url, to: backup)
                }
            } catch {
                Self.logger.error("Notes migration failed (flag not set; will retry): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func markMigrated(_ flagKey: String) {
        try? db.writer.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, '1')", arguments: [flagKey])
        }
    }
}
