// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import os.log
import VerbinalKit
@testable import Verbinal

@MainActor
final class ObservationNoteStoreTests: XCTestCase {

    /// Fresh in-memory DB per store, with the legacy-JSON importer disabled so a
    /// developer's real notes file is never read into a test.
    private func makeStore() -> ObservationNoteStore {
        ObservationNoteStore(database: try! AppDatabase.makeInMemory(), legacyNotesSource: nil)
    }

    // MARK: - ObservationNote (pure)

    func testObservationNoteIsEmptyWhenNoContent() {
        let note = ObservationNote(publisherID: "ivo://a")
        XCTAssertTrue(note.isEmpty)
    }

    func testObservationNoteIsEmptyWithWhitespaceOnlyText() {
        let note = ObservationNote(publisherID: "ivo://a", text: "   \n  ")
        XCTAssertTrue(note.isEmpty)
    }

    func testObservationNoteNotEmptyWithText() {
        let note = ObservationNote(publisherID: "ivo://a", text: "hello")
        XCTAssertFalse(note.isEmpty)
    }

    func testObservationNoteNotEmptyWithRating() {
        let note = ObservationNote(publisherID: "ivo://a", rating: 4)
        XCTAssertFalse(note.isEmpty)
    }

    func testObservationNoteNotEmptyWithTags() {
        let note = ObservationNote(publisherID: "ivo://a", tags: ["usable"])
        XCTAssertFalse(note.isEmpty)
    }

    // MARK: - Store CRUD

    func testSaveAndRetrieve() {
        let store = makeStore()
        let note = ObservationNote(
            publisherID: "ivo://cadc.nrc.ca/CFHT?2468000",
            text: "Good seeing",
            rating: 4,
            tags: ["usable", "astrometry"]
        )
        store.save(note)

        let retrieved = store.note(for: "ivo://cadc.nrc.ca/CFHT?2468000")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.text, "Good seeing")
        XCTAssertEqual(retrieved?.rating, 4)
        XCTAssertEqual(retrieved?.tags, ["usable", "astrometry"])
    }

    func testSavingEmptyNoteRemovesIt() {
        let store = makeStore()
        let note = ObservationNote(publisherID: "ivo://a", text: "hello")
        store.save(note)
        XCTAssertNotNil(store.note(for: "ivo://a"))

        store.save(ObservationNote(publisherID: "ivo://a", text: ""))
        XCTAssertNil(store.note(for: "ivo://a"), "Empty note should be removed automatically")
    }

    func testSaveUpdatesModifiedAt() {
        let store = makeStore()
        let original = ObservationNote(
            publisherID: "ivo://a",
            text: "v1",
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
        store.save(original)

        let fetched1 = store.note(for: "ivo://a")
        XCTAssertNotNil(fetched1)
        XCTAssertGreaterThan(fetched1!.modifiedAt.timeIntervalSince1970, 0, "save() should stamp modifiedAt")
    }

    func testRemove() {
        let store = makeStore()
        store.save(ObservationNote(publisherID: "ivo://a", text: "hi"))
        store.remove(publisherID: "ivo://a")
        XCTAssertNil(store.note(for: "ivo://a"))
    }

    func testRemoveUnknownPublisherIDIsNoop() {
        let store = makeStore()
        store.remove(publisherID: "ivo://does-not-exist")
        XCTAssertEqual(store.notes.count, 0)
    }

    func testMultipleNotesKeyedByPublisherID() {
        let store = makeStore()
        store.save(ObservationNote(publisherID: "ivo://a", text: "A"))
        store.save(ObservationNote(publisherID: "ivo://b", text: "B", rating: 5))

        XCTAssertEqual(store.notes.count, 2)
        XCTAssertEqual(store.note(for: "ivo://a")?.text, "A")
        XCTAssertEqual(store.note(for: "ivo://b")?.rating, 5)
    }

    func testPersistenceAcrossInstances() throws {
        // Two stores over the SAME database see each other's committed writes.
        let db = try AppDatabase.makeInMemory()
        let store1 = ObservationNoteStore(database: db, legacyNotesSource: nil)
        store1.save(ObservationNote(publisherID: "ivo://persist", text: "remembered"))

        let store2 = ObservationNoteStore(database: db, legacyNotesSource: nil)
        XCTAssertEqual(store2.note(for: "ivo://persist")?.text, "remembered")
    }

    // MARK: - Full-text search

    func testSearchFindsNoteByTextWord() {
        let store = makeStore()
        store.save(ObservationNote(publisherID: "ivo://a", text: "spiral galaxy reduction"))
        store.save(ObservationNote(publisherID: "ivo://b", text: "calibration frame"))
        XCTAssertEqual(store.searchPublisherIDs(matching: "spiral"), ["ivo://a"])
        XCTAssertEqual(store.searchPublisherIDs(matching: "galax"), ["ivo://a"], "prefix match")
    }

    func testSearchFindsNoteByTag() {
        let store = makeStore()
        store.save(ObservationNote(publisherID: "ivo://a", text: "x", tags: ["usable", "calibration"]))
        XCTAssertEqual(store.searchPublisherIDs(matching: "calibration"), ["ivo://a"])
    }

    func testSearchExcludesRemovedNotes() {
        let store = makeStore()
        store.save(ObservationNote(publisherID: "ivo://a", text: "uniquetoken here"))
        XCTAssertEqual(store.searchPublisherIDs(matching: "uniquetoken"), ["ivo://a"])
        store.remove(publisherID: "ivo://a")
        XCTAssertEqual(store.searchPublisherIDs(matching: "uniquetoken"), [], "soft-deleted notes drop out of search")
    }

    func testSearchEmptyQueryReturnsNothing() {
        let store = makeStore()
        store.save(ObservationNote(publisherID: "ivo://a", text: "content"))
        XCTAssertEqual(store.searchPublisherIDs(matching: "   "), [])
    }

    // MARK: - One-shot JSON → DB migration

    func testImportsLegacyJSONOnceThenMovesFileAside() throws {
        let sub = "VerbinalNoteMigrationTest-\(UUID().uuidString)"
        let logger = Logger(subsystem: "com.codebg.Verbinal.tests", category: "noteMig")
        let legacy = DiskPersistence<[String: ObservationNote]>(
            subdirectory: sub, fileName: "observation_notes.json", logger: logger
        )
        let dir = legacy.fileURL!.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        legacy.write([
            "ivo://x": ObservationNote(publisherID: "ivo://x", text: "legacy note", rating: 3, tags: ["old"]),
            "ivo://empty": ObservationNote(publisherID: "ivo://empty")   // empty → skipped
        ])

        let db = try AppDatabase.makeInMemory()
        let store = ObservationNoteStore(database: db, legacyNotesSource: legacy)
        XCTAssertEqual(store.note(for: "ivo://x")?.text, "legacy note")
        XCTAssertEqual(store.note(for: "ivo://x")?.rating, 3)
        XCTAssertEqual(store.note(for: "ivo://x")?.tags, ["old"])
        XCTAssertNil(store.note(for: "ivo://empty"), "empty legacy notes are skipped")
        XCTAssertEqual(store.notes.count, 1)

        // The JSON was moved aside (kept as backup, not deleted).
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.fileURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.fileURL!.appendingPathExtension("migrated").path))

        // One-shot: a second store on the same DB does not double-import.
        let store2 = ObservationNoteStore(database: db, legacyNotesSource: legacy)
        XCTAssertEqual(store2.notes.count, 1)
    }
}
