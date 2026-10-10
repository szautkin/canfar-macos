// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import GRDB
import os.log
import VerbinalKit

/// Where Research's records are kept (plan 36 5.1): the app's database,
/// each record by its key — its publisher ID and which cutout — kept whole.
/// The JSON file of before is read in once, checked (every record there),
/// and kept beside as `.migrated`. While that cannot be done, the file goes
/// on keeping them: nothing is lost.
@MainActor
final class ResearchRecords {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ResearchRecords")
    private static let migratedFlag = "researchMigrated"

    private let db: AppDatabase
    private let legacy: DiskPersistence<[DownloadedObservation]>
    private let deviceID: String
    /// False while the records are still in the file.
    private(set) var inDatabase = false

    init(database: AppDatabase, legacy: DiskPersistence<[DownloadedObservation]>) {
        self.db = database
        self.legacy = legacy
        self.deviceID = UserDefaults.standard.string(forKey: "verbinal.deviceID") ?? ""
        inDatabase = importIfNeeded()
    }

    /// Every record kept, newest first.
    func all() -> [DownloadedObservation] {
        inDatabase ? fromDatabase() : (legacy.read() ?? [])
    }

    private func fromDatabase() -> [DownloadedObservation] {
        do {
            let rows = try db.reader.read { d in
                try Data.fetchAll(d, sql: "SELECT record FROM observation WHERE removedAt IS NULL ORDER BY downloadedAt DESC")
            }
            let decoder = JSONDecoder()
            return rows.compactMap { try? decoder.decode(DownloadedObservation.self, from: $0) }
        } catch {
            Self.logger.error("Reading Research failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// `record` was kept or changed; `all` is every record now.
    func saved(_ record: DownloadedObservation, all: [DownloadedObservation]) {
        guard inDatabase else { _ = legacy.write(all); return }
        write { d in try Self.upsert(record, deviceID: self.deviceID, in: d) }
    }

    /// `records` were removed; `all` is every record now. Each stays as a
    /// mark of its removal, as the database's other records do.
    func removed(_ records: [DownloadedObservation], all: [DownloadedObservation]) {
        guard inDatabase else { _ = legacy.write(all); return }
        let now = Self.iso(Date())
        write { d in
            for record in records {
                try d.execute(sql: """
                    UPDATE observation SET removedAt = ?, updatedAt = ?, version = version + 1, lastWriterDeviceID = ?
                    WHERE uuid = ? AND removedAt IS NULL
                    """, arguments: [now, now, self.deviceID, record.id.uuidString])
            }
        }
    }

    // MARK: - The database

    private func write(_ change: (Database) throws -> Void) {
        do {
            try db.writer.write { d in try change(d) }
        } catch {
            Self.logger.error("Keeping Research failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func upsert(_ record: DownloadedObservation, deviceID: String, in d: Database) throws {
        let data = try JSONEncoder().encode(record)
        let now = iso(Date())
        // A record removed before and kept again is the new one.
        try d.execute(sql: "DELETE FROM observation WHERE recordKey = ? AND uuid != ?",
                      arguments: [record.recordKey, record.id.uuidString])
        try d.execute(sql: """
            INSERT INTO observation (uuid, recordKey, record, downloadedAt, updatedAt, version, removedAt, lastWriterDeviceID)
            VALUES (?, ?, ?, ?, ?, 1, NULL, ?)
            ON CONFLICT(uuid) DO UPDATE SET
                recordKey = excluded.recordKey, record = excluded.record, downloadedAt = excluded.downloadedAt,
                updatedAt = excluded.updatedAt, version = observation.version + 1, removedAt = NULL,
                lastWriterDeviceID = excluded.lastWriterDeviceID
            """, arguments: [record.id.uuidString, record.recordKey, data, iso(record.downloadedAt), now, deviceID])
    }

    // MARK: - The file of before

    /// Reads the file into the database once; true when the records are
    /// in the database. A check that fails keeps the file, and the records
    /// in it, for this run; the next tries again.
    private func importIfNeeded() -> Bool {
        do {
            let done = try db.reader.read { d in
                try Bool.fetchOne(d, sql: "SELECT 1 FROM meta WHERE key = ?", arguments: [Self.migratedFlag]) ?? false
            }
            if done { return true }
        } catch {
            Self.logger.error("Research's import check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        switch legacy.readResult() {
        case .unsupported(let version):
            // A newer build's file: left as it is, for it.
            Self.logger.error("Research file is format \(version), newer than this build: not imported")
            return true
        case .missing, .corrupt:
            setFlag()
            return true
        case .value(let records):
            do {
                try db.writer.write { d in
                    // Oldest first: of two records of one key, the newer stays, as `save` keeps it.
                    for record in records.sorted(by: { $0.downloadedAt < $1.downloadedAt }) {
                        try Self.upsert(record, deviceID: deviceID, in: d)
                    }
                }
                let kept = Set(fromDatabase().map(\.recordKey))
                guard Set(records.map(\.recordKey)).isSubset(of: kept) else {
                    Self.logger.error("Research import missed records: the file keeps them")
                    return false
                }
                setFlag()
                if let url = legacy.fileURL {
                    let backup = url.appendingPathExtension("migrated")
                    try? FileManager.default.removeItem(at: backup)
                    try? FileManager.default.moveItem(at: url, to: backup)
                }
                Self.logger.info("Research: \(records.count) records into the database")
                return true
            } catch {
                Self.logger.error("Research import failed (the file keeps them): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    private func setFlag() {
        write { d in try d.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, '1')", arguments: [Self.migratedFlag]) }
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
}
