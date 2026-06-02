// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Regression coverage for the Research notes cross-contamination bug: when the
/// selected observation changed, the editor committed the previous note's text
/// under the *new* observation's key, propagating one note across many items.
/// NoteEditingModel fixes this by always committing under the key the in-memory
/// fields actually belong to (`loadedID`).
@MainActor
final class NoteEditingModelTests: XCTestCase {

    private func makeStore() -> ObservationNoteStore {
        ObservationNoteStore(database: try! AppDatabase.makeInMemory(), legacyNotesSource: nil)
    }

    // MARK: - The bug

    func testSwitchingObservationsDoesNotLeakNoteText() {
        let store = makeStore()
        let model = NoteEditingModel(store: store)

        // Edit A.
        model.load(publisherID: "A")
        model.text = "Notes for A"

        // Switch to B (no explicit flush — load must flush A under A's key first).
        model.load(publisherID: "B")
        XCTAssertEqual(store.note(for: "A")?.text, "Notes for A", "A's note must be preserved")
        XCTAssertNil(store.note(for: "B"), "B must NOT inherit A's text")
        XCTAssertEqual(model.text, "", "the editor must now show B's (empty) note")

        // Edit B, then switch back to A.
        model.text = "Notes for B"
        model.load(publisherID: "A")
        XCTAssertEqual(store.note(for: "B")?.text, "Notes for B", "B's note committed under B")
        XCTAssertEqual(store.note(for: "A")?.text, "Notes for A", "A's note still intact")
        XCTAssertEqual(model.text, "Notes for A", "the editor shows A's note again")
    }

    // MARK: - Commit keying

    func testFlushCommitsUnderLoadedID() {
        let store = makeStore()
        let model = NoteEditingModel(store: store)
        model.load(publisherID: "obs-1")
        model.rating = 4
        model.tagsInput = "usable, calibration"
        model.text = "looks good"
        model.flush()

        let saved = store.note(for: "obs-1")
        XCTAssertEqual(saved?.text, "looks good")
        XCTAssertEqual(saved?.rating, 4)
        XCTAssertEqual(saved?.tags, ["usable", "calibration"])
    }

    func testFlushBeforeAnyLoadIsNoOp() {
        let store = makeStore()
        let model = NoteEditingModel(store: store)
        // Assigning fields before the first load must not write a note under any key.
        model.text = "orphan text"
        model.flush()
        XCTAssertTrue(store.notes.isEmpty, "no note may be persisted before a load() establishes a key")
    }

    // MARK: - Load / clear

    func testLoadPopulatesFromExistingNote() {
        let store = makeStore()
        store.save(ObservationNote(
            publisherID: "seed",
            text: "hello",
            rating: 3,
            tags: ["t1", "t2"],
            createdAt: Date(),
            modifiedAt: Date()
        ))

        let model = NoteEditingModel(store: store)
        model.load(publisherID: "seed")
        XCTAssertEqual(model.text, "hello")
        XCTAssertEqual(model.rating, 3)
        XCTAssertEqual(model.tagsInput, "t1, t2")
    }

    func testClearRemovesLoadedNote() {
        let store = makeStore()
        let model = NoteEditingModel(store: store)
        model.load(publisherID: "A")
        model.text = "to be cleared"
        model.flush()
        XCTAssertNotNil(store.note(for: "A"))

        model.clear()
        XCTAssertNil(store.note(for: "A"), "clear() removes the loaded note")
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(model.rating, 0)
    }

    // MARK: - Derived state

    func testParsedTagsTrimsAndDropsEmpty() {
        let store = makeStore()
        let model = NoteEditingModel(store: store)
        model.tagsInput = "a, b ,, c "
        XCTAssertEqual(model.parsedTags, ["a", "b", "c"])
    }

    func testIsEmptyReflectsFields() {
        let store = makeStore()
        let model = NoteEditingModel(store: store)
        XCTAssertTrue(model.isEmpty)
        model.text = "x"
        XCTAssertFalse(model.isEmpty)
    }
}
