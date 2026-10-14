// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import GRDB
import os.log
import VerbinalKit

/// Where Research's records are kept (plan 36 5.1): the JSON file, as they
/// always were, until the person moves them into the app's database — their
/// action alone, never a launch's (the person's word, 2026-10-09). The move
/// copies the file to a dated backup, writes every record in one
/// transaction, checks each one field by field, and switches only when all
/// match; anything else undoes it. They can be moved back to a file.
@MainActor
final class ResearchRecords {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ResearchRecords")
    private static let movedFlag = "researchMigrated"

    enum Place: String, Equatable, Sendable {
        case file, database
    }

    /// What a move came to.
    struct Moved: Equatable, Sendable {
        let records: Int
        /// The backup of the file, by its name beside it; nil moving back.
        let backup: String?
    }

    enum MoveError: LocalizedError, Equatable {
        /// Already where the move would put them.
        case alreadyThere(Place)
        /// The file was written by a newer Verbinal, or cannot be read.
        case unreadable(String)
        /// Two records share a key: one would replace the other.
        case sharedKeys([String])
        /// A record did not come back as it went.
        case mismatch(Int)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyThere(.database): String(localized: "Research is in the database already.")
            case .alreadyThere(.file): String(localized: "Research is in its file already.")
            case .unreadable(let why): String(localized: "Research's file cannot be read, so nothing was moved: \(why)")
            case .sharedKeys(let keys): String(localized: "Nothing was moved: \(keys.count) records share a key with another, and one would replace the other. \(keys.prefix(3).joined(separator: ", "))")
            case .mismatch(let count): String(localized: "Nothing was moved: \(count) records did not come back as they went, so the move was undone.")
            case .failed(let why): String(localized: "Nothing was moved: \(why)")
            }
        }
    }

    private let db: AppDatabase
    private let legacy: DiskPersistence<[DownloadedObservation]>
    private let deviceID: String
    /// Where the records are now.
    private(set) var place: Place = .file

    init(database: AppDatabase, legacy: DiskPersistence<[DownloadedObservation]>) {
        self.db = database
        self.legacy = legacy
        self.deviceID = UserDefaults.standard.string(forKey: "verbinal.deviceID") ?? ""
        place = movedFlagSet() ? .database : .file
    }

    /// Every record kept, newest first.
    func all() -> [DownloadedObservation] {
        place == .database ? fromDatabase() : (legacy.read() ?? [])
    }

    /// `record` was kept or changed; `all` is every record now.
    func saved(_ record: DownloadedObservation, all: [DownloadedObservation]) {
        guard place == .database else { _ = legacy.write(all); return }
        write { d in try Self.upsert(record, deviceID: self.deviceID, in: d) }
    }

    /// `records` were removed; `all` is every record now. Each stays as a
    /// mark of its removal, as the database's other records do.
    func removed(_ records: [DownloadedObservation], all: [DownloadedObservation]) {
        guard place == .database else { _ = legacy.write(all); return }
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

    // MARK: - The person's move

    /// Moves the records from the file into the database, as the person
    /// asked. The file is copied to a dated backup first, and kept beside
    /// as `.migrated` after; the database's records are the file's, every
    /// field, or nothing moves.
    func moveIntoDatabase(now: Date = Date()) throws -> Moved {
        guard place == .file else { throw MoveError.alreadyThere(.database) }
        let records: [DownloadedObservation]
        switch legacy.readResult() {
        case .value(let read): records = read
        case .missing: records = []
        case .unsupported(let version): throw MoveError.unreadable(String(localized: "it was written by a newer Verbinal (format \(version))"))
        case .corrupt: throw MoveError.unreadable(String(localized: "it is damaged"))
        }
        let keys = Dictionary(grouping: records, by: \.recordKey).filter { $0.value.count > 1 }.keys.sorted()
        guard keys.isEmpty else { throw MoveError.sharedKeys(keys) }

        var backup: String?
        if let url = legacy.fileURL, FileManager.default.fileExists(atPath: url.path) {
            let copy = url.deletingPathExtension().appendingPathExtension("backup-\(Self.stamp(now)).json")
            do { try FileManager.default.copyItem(at: url, to: copy) } catch {
                throw MoveError.failed(String(localized: "the backup could not be made: \(error.localizedDescription)"))
            }
            backup = copy.lastPathComponent
        }

        do {
            try db.writer.write { d in
                // The file is the truth now: whatever the database held before goes.
                try d.execute(sql: "DELETE FROM observation")
                for record in records { try Self.upsert(record, deviceID: self.deviceID, in: d) }
                let back = try Self.everyRecord(in: d)
                let mismatched = records.filter { back[$0.id] != $0 }.count + max(0, back.count - records.count)
                guard mismatched == 0 else { throw MoveError.mismatch(mismatched) }
                try d.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, '1')", arguments: [Self.movedFlag])
            }
        } catch let error as MoveError {
            throw error
        } catch {
            throw MoveError.failed(error.localizedDescription)
        }
        place = .database
        if let url = legacy.fileURL, FileManager.default.fileExists(atPath: url.path) {
            let aside = url.appendingPathExtension("migrated")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
        }
        Self.logger.info("Research: \(records.count) records moved into the database, as the person asked")
        return Moved(records: records.count, backup: backup)
    }

    /// Moves the records back from the database into the file, as the
    /// person asked: written, read back and checked, and only then is the
    /// database left aside.
    func moveBackToFile() throws -> Moved {
        guard place == .database else { throw MoveError.alreadyThere(.file) }
        let records = fromDatabase()
        guard legacy.write(records) else { throw MoveError.failed(String(localized: "the file could not be written")) }
        let back = Dictionary(uniqueKeysWithValues: (legacy.read() ?? []).map { ($0.id, $0) })
        let mismatched = records.filter { back[$0.id] != $0 }.count
        guard mismatched == 0, back.count == records.count else {
            throw MoveError.mismatch(max(mismatched, abs(back.count - records.count)))
        }
        do {
            try db.writer.write { d in try d.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [Self.movedFlag]) }
        } catch {
            throw MoveError.failed(error.localizedDescription)
        }
        place = .file
        Self.logger.info("Research: \(records.count) records moved back into their file, as the person asked")
        return Moved(records: records.count, backup: nil)
    }

    // MARK: - The database

    private func movedFlagSet() -> Bool {
        (try? db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT 1 FROM meta WHERE key = ?", arguments: [Self.movedFlag])
        }) ?? false
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

    /// Every live record in `d`, by id — what the move checks against.
    private static func everyRecord(in d: Database) throws -> [UUID: DownloadedObservation] {
        let decoder = JSONDecoder()
        let rows = try Data.fetchAll(d, sql: "SELECT record FROM observation WHERE removedAt IS NULL")
        return Dictionary(uniqueKeysWithValues: try rows.map { data in
            let record = try decoder.decode(DownloadedObservation.self, from: data)
            return (record.id, record)
        })
    }

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

    private static let isoFormatter = ISO8601DateFormatter()
    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
