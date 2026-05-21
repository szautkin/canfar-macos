// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class ObservationNoteStoreTests: XCTestCase {

    private func makeStore() -> ObservationNoteStore {
        ObservationNoteStore(fileName: "test_notes_\(UUID().uuidString).json")
    }

    override func tearDown() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal") {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("test_notes_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        super.tearDown()
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

    func testPersistenceAcrossInstances() {
        let fileName = "test_notes_persist_\(UUID().uuidString).json"
        let store1 = ObservationNoteStore(fileName: fileName)
        store1.save(ObservationNote(publisherID: "ivo://persist", text: "remembered"))

        let store2 = ObservationNoteStore(fileName: fileName)
        XCTAssertEqual(store2.note(for: "ivo://persist")?.text, "remembered")
    }
}
