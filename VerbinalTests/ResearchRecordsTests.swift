// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import os
import VerbinalKit
@testable import Verbinal

/// Plan 36 5.1, as the person decided (2026-10-09): Research's records stay
/// in their file until the person moves them into the database — no launch
/// does it. The move backs the file up, checks every record, and is undone
/// by any mismatch; they can be moved back.
@MainActor
final class ResearchRecordsTests: XCTestCase {

    private var fileName = ""

    override func setUp() {
        super.setUp()
        fileName = "test-records-\(UUID().uuidString).json"
    }

    override func tearDown() {
        if let url = legacy().fileURL {
            let folder = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension().lastPathComponent
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(stem) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        super.tearDown()
    }

    private func legacy() -> DiskPersistence<[DownloadedObservation]> {
        DiskPersistence(subdirectory: "Verbinal", fileName: fileName, logger: Logger(subsystem: "test", category: "records"))
    }

    private func record(_ id: String, cutout: CutoutSpec? = nil) -> DownloadedObservation {
        var record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?\(id)/\(id)p", collection: "CFHT", observationID: id,
                                           targetName: "M31", instrument: "", filter: "", ra: "", dec: "", startDate: "",
                                           calLevel: "", localPath: "")
        record.cutout = cutout
        return record
    }

    private func backups() throws -> [String] {
        let url = try XCTUnwrap(legacy().fileURL)
        let stem = url.deletingPathExtension().lastPathComponent
        return (try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))
            .filter { $0.hasPrefix(stem + ".backup-") }
    }

    func testNothingMovesUntilThePersonAsks() throws {
        let db = try AppDatabase.makeInMemory()
        XCTAssertTrue(legacy().write([record("1525350"), record("2388466")]))
        let store = ObservationStore(fileName: fileName, spotlight: nil, database: db)
        XCTAssertEqual(store.recordsPlace, .file, "a launch moves nothing")
        XCTAssertEqual(store.observations.count, 2)
        let rows = try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observation") }
        XCTAssertEqual(rows, 0)
        let url = try XCTUnwrap(legacy().fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the file stays where it is")
    }

    func testTheMoveBacksUpChecksEveryRecordAndCanBeUndone() throws {
        let db = try AppDatabase.makeInMemory()
        let whole = record("1525350")
        let cut = record("1525350", cutout: CutoutSpec(artifactID: "cadc:CFHT/1525350p.fits.fz", region: .circle(ra: 10.68, dec: 41.27, radius: 0.01)))
        XCTAssertTrue(legacy().write([whole, cut, record("2388466")]))
        let store = ObservationStore(fileName: fileName, spotlight: nil, database: db)
        let before = store.observations

        let moved = try store.moveIntoDatabase()
        XCTAssertEqual(moved.records, 3, "a cutout beside the whole observation: the key is the record")
        XCTAssertEqual(store.recordsPlace, .database)
        XCTAssertEqual(try backups().count, 1, "a dated backup, beside the file")
        let url = try XCTUnwrap(legacy().fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("migrated").path))
        XCTAssertEqual(Set(store.observations.map(\.id)), Set(before.map(\.id)))
        XCTAssertEqual(ObservationStore(fileName: fileName, spotlight: nil, database: db).recordsPlace, .database,
                       "a later launch reads the database")

        let back = try store.moveBackToFile()
        XCTAssertEqual(back.records, 3)
        XCTAssertEqual(store.recordsPlace, .file)
        let reread = ObservationStore(fileName: fileName, spotlight: nil, database: db)
        XCTAssertEqual(reread.recordsPlace, .file)
        XCTAssertEqual(Set(reread.observations.map(\.id)), Set(before.map(\.id)), "the file holds them again")
    }

    func testRecordsSharingAKeyMoveNothing() throws {
        let db = try AppDatabase.makeInMemory()
        var twin = record("1525350")
        twin.id = UUID()
        XCTAssertTrue(legacy().write([record("1525350"), twin]))
        let store = ObservationStore(fileName: fileName, spotlight: nil, database: db)
        XCTAssertThrowsError(try store.moveIntoDatabase()) { error in
            guard case ResearchRecords.MoveError.sharedKeys(let keys) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(keys.count, 1)
        }
        XCTAssertEqual(store.recordsPlace, .file)
        XCTAssertEqual(store.observations.count, 2, "nothing lost")
        XCTAssertEqual(try backups().count, 0, "nothing done")
    }

    func testARemovedRecordStaysAMarkInTheDatabase() throws {
        let db = try AppDatabase.makeInMemory()
        let store = ObservationStore(fileName: fileName, spotlight: nil, database: db)
        try store.moveIntoDatabase()
        let kept = store.save(record("1525350"))
        store.remove(kept)
        XCTAssertTrue(ObservationStore(fileName: fileName, spotlight: nil, database: db).observations.isEmpty)
        let marks = try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observation WHERE removedAt IS NOT NULL") }
        XCTAssertEqual(marks, 1)

        var anew = record("1525350")
        anew.id = UUID()
        store.save(anew)
        XCTAssertEqual(ObservationStore(fileName: fileName, spotlight: nil, database: db).observations.map(\.id), [anew.id])
    }

    func testAFileSentToStorageIsRecordedWithItsRecord() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("1525350p.fits.fz")
        FileManager.default.createFile(atPath: file.path, contents: Data("SIMPLE".utf8))
        let store = ObservationStore(fileName: fileName, spotlight: nil, database: try AppDatabase.makeInMemory())
        var downloaded = record("1525350")
        downloaded.localPath = file.path
        store.save(downloaded)
        store.noteInStorage(file, at: "Verbinal-Results/research/1525350p.fits.fz")
        XCTAssertEqual(store.observations.first?.storagePath, "Verbinal-Results/research/1525350p.fits.fz")
    }
}
