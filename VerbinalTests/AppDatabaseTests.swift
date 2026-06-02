// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import GRDB
@testable import Verbinal

/// Phase 1-B: the GRDB schema + migrator + external-content FTS5 over notes.
final class AppDatabaseTests: XCTestCase {

    func testMigratorCreatesExpectedTables() throws {
        let db = try AppDatabase.makeInMemory()
        let tables = try db.reader.read { d in
            try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        for expected in ["observation", "note", "noteTag", "noteSearch"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected); got \(tables)")
        }
    }

    func testNoteIsFullTextSearchableByText() throws {
        let db = try AppDatabase.makeInMemory()
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO note (uuid, publisherID, text, rating, tags)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["u1", "ivo://cadc/A", "spiral galaxy calibration frame", 4, "usable, calibration"])
        }
        // External-content FTS5: noteSearch.rowid == note.rowid (kept by synchronize).
        let hits = try db.reader.read { d in
            try String.fetchAll(d, sql: """
                SELECT note.publisherID FROM noteSearch
                JOIN note ON note.rowid = noteSearch.rowid
                WHERE noteSearch MATCH ?
                """, arguments: ["spiral"])
        }
        XCTAssertEqual(hits, ["ivo://cadc/A"], "FTS should find the note by a word in its text")
    }

    func testNoteIsFullTextSearchableByTag() throws {
        let db = try AppDatabase.makeInMemory()
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO note (uuid, publisherID, text, rating, tags)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["u1", "ivo://cadc/B", "nice frame", 0, "usable, calibration"])
        }
        let hits = try db.reader.read { d in
            try String.fetchAll(d, sql: """
                SELECT note.publisherID FROM noteSearch
                JOIN note ON note.rowid = noteSearch.rowid
                WHERE noteSearch MATCH ?
                """, arguments: ["calibration"])
        }
        XCTAssertEqual(hits, ["ivo://cadc/B"], "FTS should find the note by a denormalized tag")
    }

    func testDeletingNoteCascadesTagsAndUpdatesFTS() throws {
        let db = try AppDatabase.makeInMemory()
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO note (uuid, publisherID, text, tags) VALUES (?,?,?,?)",
                          arguments: ["u1", "ivo://cadc/C", "deleteme content", "tagx"])
            try d.execute(sql: "INSERT INTO noteTag (noteUUID, tag) VALUES (?,?)", arguments: ["u1", "tagx"])
            try d.execute(sql: "DELETE FROM note WHERE uuid = ?", arguments: ["u1"])
        }
        try db.reader.read { d in
            let tagRows = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM noteTag")!
            XCTAssertEqual(tagRows, 0, "ON DELETE CASCADE should remove the note's tags")
            let ftsHits = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM noteSearch WHERE noteSearch MATCH ?",
                                           arguments: ["deleteme"])!
            XCTAssertEqual(ftsHits, 0, "synchronize trigger should drop the deleted note from the FTS index")
        }
    }
}
