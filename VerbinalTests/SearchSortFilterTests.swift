// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class SearchSortFilterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SearchResultColumns.clearPersistedVisibility()
    }

    private func makeModel() -> SearchResultsModel {
        let model = SearchResultsModel()
        let headers = ["\"Collection\"", "\"Target Name\"", "\"Cal. Lev.\""]
        let rows = [
            ["JWST", "M31", "2"],
            ["HST", "NGC 1234", "1"],
            ["CFHT", "M51", "3"],
            ["JWST", "M101", "2"],
        ]
        model.loadResults(headers: headers, rows: rows, query: "SELECT *", maxRec: 30000)
        return model
    }

    private func collection(of row: SearchResult, model: SearchResultsModel) -> String {
        model.columns.value(in: row, forID: "collection")
    }

    private func targetName(of row: SearchResult, model: SearchResultsModel) -> String {
        model.columns.value(in: row, forID: "targetname")
    }

    // MARK: - Sorting

    func testSortByCollectionAscending() {
        let model = makeModel()
        model.toggleSort("collection")
        let sorted = model.displayedRows
        XCTAssertEqual(collection(of: sorted[0], model: model), "CFHT")
        XCTAssertEqual(collection(of: sorted[1], model: model), "HST")
        XCTAssertEqual(collection(of: sorted[2], model: model), "JWST")
    }

    func testSortByCollectionDescending() {
        let model = makeModel()
        model.toggleSort("collection") // ascending
        model.toggleSort("collection") // descending
        let sorted = model.displayedRows
        XCTAssertEqual(collection(of: sorted[0], model: model), "JWST")
    }

    func testSortByCalLevelNumeric() {
        let model = makeModel()
        model.toggleSort("callev")
        let sorted = model.displayedRows
        XCTAssertEqual(model.columns.value(in: sorted[0], forID: "callev"), "1")
        XCTAssertEqual(model.columns.value(in: sorted[1], forID: "callev"), "2")
    }

    func testSortHasDeterministicTiebreaker() {
        // Two rows share collection="JWST" and callev="2".
        // After sort by collection, their relative order must be stable
        // regardless of toggle direction — no shuffling on flip.
        let model = makeModel()
        model.toggleSort("collection")
        let asc1 = model.displayedRows.map { $0.id }
        model.toggleSort("collection")
        model.toggleSort("collection")
        let asc2 = model.displayedRows.map { $0.id }
        XCTAssertEqual(asc1, asc2, "Ascending sort must be deterministic across round-trip toggles")
    }

    func testNaNAndInfSortLast() {
        let model = SearchResultsModel()
        let headers = ["\"Collection\"", "\"Value\""]
        let rows = [
            ["A", "10"],
            ["B", "NaN"],
            ["C", "5"],
            ["D", "Infinity"],
            ["E", "7"],
        ]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 100)
        model.toggleSort("value")
        let sorted = model.displayedRows
        // Finite values first (5, 7, 10), then non-finite.
        let values = sorted.map { model.columns.value(in: $0, forID: "value") }
        XCTAssertEqual(values.prefix(3), ["5", "7", "10"])
    }

    // MARK: - Filtering

    func testFilterByCollection() {
        let model = makeModel()
        model.setFilter("collection", text: "JWST")
        XCTAssertEqual(model.filteredCount, 2)
        for row in model.displayedRows {
            XCTAssertEqual(collection(of: row, model: model), "JWST")
        }
    }

    func testFilterCaseInsensitive() {
        let model = makeModel()
        model.setFilter("collection", text: "jwst")
        XCTAssertEqual(model.filteredCount, 2)
    }

    func testFilterByTarget() {
        let model = makeModel()
        model.setFilter("targetname", text: "M31")
        XCTAssertEqual(model.filteredCount, 1)
        XCTAssertEqual(targetName(of: model.displayedRows[0], model: model), "M31")
    }

    func testFilterEmptyRemovesEntry() {
        let model = makeModel()
        model.setFilter("collection", text: "JWST")
        model.setFilter("collection", text: "")
        XCTAssertEqual(model.filteredCount, 4)
        XCTAssertTrue(model.columnFilters["collection"] == nil, "Empty filter should be removed from the dict")
    }

    func testFilterNoMatch() {
        let model = makeModel()
        model.setFilter("collection", text: "NONEXISTENT")
        XCTAssertEqual(model.filteredCount, 0)
    }

    func testFilterMatchesFormattedValue() {
        // callev raw is "1", formatted is "Cal". Filtering by "cal" should match.
        let model = makeModel()
        model.setFilter("callev", text: "cal")
        XCTAssertEqual(model.filteredCount, 1)
        XCTAssertEqual(model.columns.value(in: model.displayedRows[0], forID: "callev"), "1")
    }

    // MARK: - Operator-aware numeric filters

    private func makeNumericModel() -> SearchResultsModel {
        let model = SearchResultsModel()
        let headers = ["\"Collection\"", "\"Score\""]
        let rows = [
            ["A", "1"],
            ["B", "5"],
            ["C", "10"],
            ["D", "15"],
        ]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 100)
        return model
    }

    func testNumericFilterLessThan() {
        let model = makeNumericModel()
        model.setFilter("score", text: "<10")
        XCTAssertEqual(model.filteredCount, 2)
    }

    func testNumericFilterGreaterOrEqual() {
        let model = makeNumericModel()
        model.setFilter("score", text: ">=10")
        XCTAssertEqual(model.filteredCount, 2)
    }

    func testNumericFilterEquality() {
        let model = makeNumericModel()
        model.setFilter("score", text: "=5")
        XCTAssertEqual(model.filteredCount, 1)
    }

    func testNumericFilterPlainNumberIsEquality() {
        let model = makeNumericModel()
        model.setFilter("score", text: "15")
        XCTAssertEqual(model.filteredCount, 1)
    }

    func testTextColumnIgnoresOperatorSyntax() {
        // "collection" is text — a <5-style filter should NOT do a numeric
        // comparison; it falls back to substring matching (no match).
        let model = makeNumericModel()
        model.setFilter("collection", text: "<10")
        XCTAssertEqual(model.filteredCount, 0)
    }

    // MARK: - Pagination

    func testPaginationDefault() {
        let model = makeModel()
        model.rowsPerPage = 2
        XCTAssertEqual(model.displayedRows.count, 2)
        XCTAssertEqual(model.totalPages, 2)
    }

    func testPaginationSecondPage() {
        let model = makeModel()
        model.rowsPerPage = 2
        model.currentPage = 1
        XCTAssertEqual(model.displayedRows.count, 2)
    }

    func testPaginationAllRows() {
        let model = makeModel()
        model.rowsPerPage = 0 // all
        XCTAssertEqual(model.displayedRows.count, 4)
        XCTAssertEqual(model.totalPages, 1)
    }

    func testFilterResetsPagination() {
        let model = makeModel()
        model.rowsPerPage = 2
        model.currentPage = 1
        model.setFilter("collection", text: "JWST")
        XCTAssertEqual(model.currentPage, 0, "Filter should reset to page 0")
    }

    func testSortResetsPagination() {
        let model = makeModel()
        model.rowsPerPage = 2
        model.currentPage = 1
        model.toggleSort("collection")
        XCTAssertEqual(model.currentPage, 0, "Sort should reset to page 0")
    }

    func testPageSizeChangeClampsCurrentPage() {
        // 4 rows × rowsPerPage=2 = page 0-1. Navigate to page 1, then bump
        // to rowsPerPage=10: currentPage=1 is out of range (only page 0 exists).
        let model = makeModel()
        model.rowsPerPage = 2
        model.currentPage = 1
        model.rowsPerPage = 10
        XCTAssertEqual(model.currentPage, 0, "rowsPerPage change must clamp currentPage")
        XCTAssertEqual(model.displayedRows.count, 4)
    }

    func testFilterShrinkDoesNotStrandOnEmptyPage() {
        let model = makeModel()
        model.rowsPerPage = 2
        model.currentPage = 1
        // After filter, filteredCount=2 → one page. currentPage resets to 0.
        model.setFilter("collection", text: "JWST")
        XCTAssertEqual(model.displayedRows.count, 2)
    }

    // MARK: - Combined Sort + Filter

    func testSortAndFilterTogether() {
        let model = makeModel()
        model.setFilter("collection", text: "JWST")
        model.toggleSort("targetname")
        let results = model.displayedRows
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(targetName(of: results[0], model: model), "M101") // M101 < M31 alphabetically
        XCTAssertEqual(targetName(of: results[1], model: model), "M31")
    }

    // MARK: - Core comparator

    func testCompareNumberNaN() {
        XCTAssertEqual(
            SearchResultsModel.compare("3.0", "NaN", kind: .number),
            .orderedAscending,
            "Finite value should sort before NaN"
        )
    }

    func testCompareNumberBothValid() {
        XCTAssertEqual(
            SearchResultsModel.compare("10", "3", kind: .number),
            .orderedDescending
        )
    }

    func testCompareTextLocalized() {
        XCTAssertEqual(
            SearchResultsModel.compare("alpha", "Beta", kind: .text),
            .orderedAscending
        )
    }
}
