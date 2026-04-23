// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ColumnKindInferenceTests: XCTestCase {

    func testNumericColumnInferredAsNumber() {
        let cols = SearchResultColumns(
            headers: ["\"Score\""],
            sampleRows: [["1.5"], ["2.7"], ["3.14"]]
        )
        XCTAssertEqual(cols.list[0].kind, .number)
    }

    func testIntegerColumnInferredAsInteger() {
        let cols = SearchResultColumns(
            headers: ["\"Count\""],
            sampleRows: [["1"], ["2"], ["3"]]
        )
        XCTAssertEqual(cols.list[0].kind, .integer)
    }

    func testMixedColumnFallsToText() {
        let cols = SearchResultColumns(
            headers: ["\"Mix\""],
            sampleRows: [["1"], ["two"], ["3"]]
        )
        XCTAssertEqual(cols.list[0].kind, .text)
    }

    func testISODatesInferred() {
        let cols = SearchResultColumns(
            headers: ["\"When\""],
            sampleRows: [["2024-03-15T10:00:00Z"], ["2024-04-20T12:00:00Z"]]
        )
        XCTAssertEqual(cols.list[0].kind, .isoDate)
    }

    func testBooleanColumnInferred() {
        let cols = SearchResultColumns(
            headers: ["\"Flag\""],
            sampleRows: [["true"], ["false"], ["true"]]
        )
        XCTAssertEqual(cols.list[0].kind, .boolean)
    }

    func testKnownOverridesTrumpInference() {
        // startdate values look numeric but the override forces .mjdDate.
        let cols = SearchResultColumns(
            headers: ["\"startdate\""],
            sampleRows: [["59000.0"]]
        )
        XCTAssertEqual(cols.list[0].kind, .mjdDate)
    }

    func testEmptyColumnIsText() {
        let cols = SearchResultColumns(
            headers: ["\"Empty\""],
            sampleRows: [[""], [""], [""]]
        )
        XCTAssertEqual(cols.list[0].kind, .text)
    }

    func testDuplicateHeadersDisambiguated() {
        // "Foo Bar" → "foobar" (space stripped) and "Foo.Bar" → "foobar" (dot stripped).
        let cols = SearchResultColumns(
            headers: ["\"Foo Bar\"", "\"Foo.Bar\""],
            sampleRows: [["1", "2"]]
        )
        XCTAssertEqual(cols.list.count, 2)
        XCTAssertEqual(cols.list[0].id, "foobar")
        XCTAssertEqual(cols.list[1].id, "foobar_2")
    }

    func testValueByIDSafeForMissingColumns() {
        let cols = SearchResultColumns(
            headers: ["\"A\""],
            sampleRows: [["1"]]
        )
        let row = SearchResult(id: "x", rawValues: ["hello"], searchIndex: ["hello"])
        XCTAssertEqual(cols.value(in: row, forID: "a"), "hello")
        XCTAssertEqual(cols.value(in: row, forID: "missing"), "")
    }

    func testValueByIDSafeForShortRow() {
        let cols = SearchResultColumns(
            headers: ["\"A\"", "\"B\""],
            sampleRows: [["1", "2"]]
        )
        let shortRow = SearchResult(id: "x", rawValues: ["only-one"], searchIndex: ["only-one"])
        XCTAssertEqual(cols.value(in: shortRow, forID: "a"), "only-one")
        // B index is 1, but row only has one value — safe empty string, no crash.
        XCTAssertEqual(cols.value(in: shortRow, forID: "b"), "")
    }
}
