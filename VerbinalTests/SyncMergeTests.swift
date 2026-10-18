// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import MCPCore
@testable import Verbinal

/// Plan 45 F1: the three-way merge, field by field, with no clock in it.
final class SyncMergeTests: XCTestCase {
    private func note(_ text: String, rating: Int = 3, tags: [String] = ["usable"]) -> [String: JSONValue] {
        ["note": .object(["text": .string(text), "rating": .int(rating), "tags": .array(tags.map(JSONValue.string))])]
    }

    func testFieldsChangedOnDifferentSidesBothStay() {
        let base = note("seeing 0.6")
        let mine = note("seeing 0.6", rating: 5)
        let theirs = note("seeing 0.6", tags: ["usable", "candidate"])
        let result = SyncMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(result.merged, note("seeing 0.6", rating: 5, tags: ["usable", "candidate"]))
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testTheSameChangeOnBothSidesIsNoConflict() {
        let result = SyncMerge.merge(base: note("a"), mine: note("b"), theirs: note("b"))
        XCTAssertEqual(result.merged, note("b"))
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    /// Decided 1: storage's value stays; this Mac's waits, with both told.
    func testAFieldBothChangedKeepsStoragesAndSaysSo() {
        let result = SyncMerge.merge(base: note("first", rating: 3), mine: note("from this Mac", rating: 4),
                                     theirs: note("from the other", rating: 3))
        XCTAssertEqual(result.merged, note("from the other", rating: 4), "the rating, changed here only, merges")
        XCTAssertEqual(result.conflicts, [SyncMerge.Conflict(path: ["note", "text"], mine: .string("from this Mac"),
                                                             theirs: .string("from the other"))])
    }

    func testAListIsOneField() {
        let result = SyncMerge.merge(base: note("a", tags: ["x"]), mine: note("a", tags: ["x", "mine"]),
                                     theirs: note("a", tags: ["x", "theirs"]))
        XCTAssertEqual(result.conflicts.map(\.path), [["note", "tags"]])
        XCTAssertEqual(result.merged, note("a", tags: ["x", "theirs"]))
    }

    func testAddedAndRemovedKeys() {
        let base: [String: JSONValue] = ["a": .int(1), "b": .int(2)]
        // Added here, removed there: each side's own change stays.
        let merged = SyncMerge.merge(base: base, mine: ["a": .int(1), "b": .int(2), "c": .int(3)],
                                     theirs: ["a": .int(1)])
        XCTAssertEqual(merged.merged, ["a": .int(1), "c": .int(3)])
        XCTAssertTrue(merged.conflicts.isEmpty)
        // Removed there, changed here: a conflict, storage's (removed) stays.
        let clash = SyncMerge.merge(base: base, mine: ["a": .int(1), "b": .int(20)], theirs: ["a": .int(1)])
        XCTAssertEqual(clash.merged, ["a": .int(1)])
        XCTAssertEqual(clash.conflicts, [SyncMerge.Conflict(path: ["b"], mine: .int(20), theirs: nil)])
    }

    /// Two devices before their first sync: what differs is a conflict;
    /// what only one has is that one's.
    func testNoCommonPast() {
        let result = SyncMerge.merge(base: nil, mine: ["name": .string("M31 deep"), "pinned": .bool(true)],
                                     theirs: ["name": .string("M31"), "adql": .string("SELECT 1")])
        XCTAssertEqual(result.merged, ["name": .string("M31"), "pinned": .bool(true), "adql": .string("SELECT 1")])
        XCTAssertEqual(result.conflicts.map(\.path), [["name"]])
    }

    /// Live, F3: the field read "record.name" — the file's wrapper, not the person's word.
    func testAFieldIsNamedAsThePersonReadsIt() {
        XCTAssertEqual(SyncMerge.Conflict(path: ["record", "name"], mine: nil, theirs: nil).field, "name")
        XCTAssertEqual(SyncMerge.Conflict(path: ["note", "text"], mine: nil, theirs: nil).field, "note.text")
        XCTAssertEqual(SyncMerge.Conflict(path: ["record"], mine: nil, theirs: nil).field, "record")
    }

    func testAnObjectReplacedByAValueIsOneField() {
        let result = SyncMerge.merge(base: ["cutout": .object(["r": .int(1)])], mine: ["cutout": .null],
                                     theirs: ["cutout": .object(["r": .int(2)])])
        XCTAssertEqual(result.conflicts.map(\.path), [["cutout"]])
        XCTAssertEqual(result.merged["cutout"], .object(["r": .int(2)]))
    }
}
