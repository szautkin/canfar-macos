// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import GRDB
import os.log

/// The app's single GRDB database (Phase 1 of the storage-DB migration; see
/// dev_info/storage_review_1/DB_DESIGN.md). Owns one `DatabaseWriter` —
/// `DatabasePool` (WAL: concurrent reads, serialized writes off the main actor)
/// on disk, `DatabaseQueue` in memory for tests.
///
/// Phase 1 scope: observations + notes + note_tags + an external-content FTS5
/// index over notes, so users can find a download by what they wrote about it.
/// The schema is locked for future cross-device sync (stable UUID PKs, updatedAt,
/// version, soft-delete tombstones, lastWriterDeviceID) even though sync/export
/// ship later. `bookmarkData`/`agentAttribution` are device-local (excluded from
/// the future portable JSON export).
struct AppDatabase {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "AppDatabase")

    /// The writer (a `DatabasePool` on disk). Reads also go through it.
    let writer: any DatabaseWriter
    var reader: any DatabaseReader { writer }

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk pool at Application Support/Verbinal/verbinal.sqlite (WAL).
    static func makeShared() throws -> AppDatabase {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Verbinal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("verbinal.sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        logger.info("Opened DB at \(dbURL.lastPathComponent, privacy: .public)")
        return try AppDatabase(pool)
    }

    /// In-memory queue for tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    /// Process-wide shared database (the app's single local store). Falls back to
    /// an in-memory database if the on-disk file can't be opened, so a storage
    /// failure degrades to a session-only store rather than crashing the app
    /// (mirrors `DiskPersistence`'s nil-fileURL no-op resilience).
    static let shared: AppDatabase = {
        do {
            return try makeShared()
        } catch {
            logger.error("On-disk DB open failed: \(error.localizedDescription, privacy: .public) — falling back to in-memory (no persistence this session)")
            // makeInMemory only fails on a malformed migration, which is a
            // programmer error caught in tests, not a runtime condition.
            return try! makeInMemory()
        }
    }()

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // Downloaded observations. PK = the existing DownloadedObservation.id
            // UUID (stable sync identity); publisherID is the natural/dedup key.
            try db.create(table: "observation") { t in
                t.primaryKey("uuid", .text).notNull()
                t.column("publisherID", .text).notNull()
                t.column("collection", .text)
                t.column("observationID", .text)
                t.column("targetName", .text)
                t.column("instrument", .text)
                t.column("filter", .text)
                t.column("calLevel", .integer)
                t.column("localPath", .text)
                t.column("fileSize", .integer)
                t.column("thumbnailURL", .text)
                t.column("previewURL", .text)
                // Device-local, excluded from the future portable export:
                t.column("bookmarkData", .blob)
                t.column("agentAttribution", .text)   // JSON; device-local
                // Timestamps as ISO8601 UTC text (portable, stable round-trip):
                t.column("createdAt", .text)
                t.column("downloadedAt", .text)
                // Sync-readiness columns:
                t.column("updatedAt", .text)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("deletedAt", .text)            // soft-delete tombstone (NULL = live)
                t.column("lastWriterDeviceID", .text)
                t.uniqueKey(["publisherID"])
            }

            // Per-observation notes. Keyed by publisherID (notes outlive the local
            // file copy), with a stable surrogate UUID as the merge identity.
            try db.create(table: "note") { t in
                t.primaryKey("uuid", .text).notNull()
                t.column("publisherID", .text).notNull().unique()
                t.column("text", .text).notNull().defaults(to: "")
                t.column("rating", .integer).notNull().defaults(to: 0)
                // Denormalized tag string (feeds FTS via synchronize); the
                // normalized side table below backs facet/filter-by-tag.
                t.column("tags", .text).notNull().defaults(to: "")
                t.column("agentAttribution", .text)     // JSON; device-local, excluded from export
                t.column("createdAt", .text)
                t.column("modifiedAt", .text)           // display only
                t.column("updatedAt", .text)            // sync clock
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("deletedAt", .text)
                t.column("lastWriterDeviceID", .text)
            }

            // Normalized tags for faceting ("all notes tagged calibration").
            try db.create(table: "noteTag") { t in
                t.column("noteUUID", .text).notNull()
                    .references("note", column: "uuid", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["noteUUID", "tag"])
            }
            try db.create(index: "noteTag_on_tag", on: "noteTag", columns: ["tag"])

            // External-content FTS5 over the note's text + denormalized tags.
            // `synchronize` installs triggers that keep the index in step with the
            // `note` table automatically. The index is Apple-side only and never
            // part of the portable export (FTS5 isn't universally available).
            try db.create(virtualTable: "noteSearch", using: FTS5()) { t in
                t.synchronize(withTable: "note")
                t.column("text")
                t.column("tags")
                t.tokenizer = .porter(wrapping: .unicode61())
            }

            // App-level key/value metadata (e.g. one-shot migration flags). Separate
            // from DatabaseMigrator's own internal schema-version bookkeeping.
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text)
            }
        }

        // v2 — AI Guide: per-tool description overrides + user-authored
        // instruction tools. The tool's built-in description is the single
        // source of truth and is NEVER stored here; an override row is a sparse
        // delta and "reset" soft-deletes it. Same sync-ready column convention
        // as v1 (uuid PK, updatedAt, version, deletedAt, lastWriterDeviceID).
        migrator.registerMigration("v2") { db in
            try db.create(table: "aiToolOverride") { t in
                t.primaryKey("uuid", .text).notNull()
                t.column("toolName", .text).notNull()
                t.column("userDescription", .text).notNull()
                t.column("createdAt", .text)
                t.column("updatedAt", .text)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("deletedAt", .text)               // soft-delete tombstone (NULL = live)
                t.column("lastWriterDeviceID", .text)
                t.uniqueKey(["toolName"])                   // one override per tool (ON CONFLICT target)
            }
            // User-authored "instruction tools": named, read-only guidance the
            // agent discovers in tools/list and can call to receive `body`.
            // Name uniqueness among LIVE rows is enforced in the service (so a
            // soft-deleted name can be reused), hence no DB UNIQUE here.
            try db.create(table: "aiGuideTool") { t in
                t.primaryKey("uuid", .text).notNull()
                t.column("name", .text).notNull()
                t.column("description", .text).notNull()
                t.column("body", .text)
                t.column("orderIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text)
                t.column("updatedAt", .text)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("deletedAt", .text)
                t.column("lastWriterDeviceID", .text)
            }
        }

        return migrator
    }
}
