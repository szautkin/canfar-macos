// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import os
import VerbinalKit
@testable import Verbinal

/// Plan 36 5.1: Research's records in the database, each by its key; the
/// JSON file of before read in once, checked, and kept beside.
@MainActor
final class ResearchRecordsTests: XCTestCase {

    private var fileName = ""

    override func setUp() {
        super.setUp()
        fileName = "test-records-\(UUID().uuidString).json"
    }

    override func tearDown() {
        if let url = legacy().fileURL {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("migrated"))
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

    func testTheFileIsReadInOnceCheckedAndKeptBeside() throws {
        let db = try AppDatabase.makeInMemory()
        let whole = record("1525350")
        let cut = record("1525350", cutout: CutoutSpec(artifactID: "cadc:CFHT/1525350p.fits.fz", region: .circle(ra: 10.68, dec: 41.27, radius: 0.01)))
        XCTAssertTrue(legacy().write([whole, cut, record("2388466")]))

        let store = ObservationStore(fileName: fileName, spotlight: nil, database: db)
        XCTAssertEqual(store.observations.count, 3, "a cutout beside the whole observation: the key is the record")
        let url = try XCTUnwrap(legacy().fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("migrated").path), "kept beside")

        let again = ObservationStore(fileName: fileName, spotlight: nil, database: db)
        XCTAssertEqual(Set(again.observations.map(\.id)), Set(store.observations.map(\.id)), "the same records, read once")
    }

    func testARemovedRecordStaysAMarkAndOneKeptAgainIsNew() throws {
        let db = try AppDatabase.makeInMemory()
        let store = ObservationStore(fileName: fileName, spotlight: nil, database: db)
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
