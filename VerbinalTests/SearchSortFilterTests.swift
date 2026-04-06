// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class SearchSortFilterTests: XCTestCase {

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

    // MARK: - Sorting

    func testSortByCollectionAscending() {
        let model = makeModel()
        model.toggleSort("collection")
        let sorted = model.sortedResults
        XCTAssertEqual(sorted[0].collection, "CFHT")
        XCTAssertEqual(sorted[1].collection, "HST")
        XCTAssertEqual(sorted[2].collection, "JWST")
    }

    func testSortByCollectionDescending() {
        let model = makeModel()
        model.toggleSort("collection") // ascending
        model.toggleSort("collection") // descending
        let sorted = model.sortedResults
        XCTAssertEqual(sorted[0].collection, "JWST")
    }

    func testSortByCalLevelNumeric() {
        let model = makeModel()
        model.toggleSort("callev")
        let sorted = model.sortedResults
        XCTAssertEqual(sorted[0].values["callev"], "1")
        XCTAssertEqual(sorted[1].values["callev"], "2")
    }

    // MARK: - Filtering

    func testFilterByCollection() {
        let model = makeModel()
        model.setFilter("collection", text: "JWST")
        XCTAssertEqual(model.filteredCount, 2)
        XCTAssertTrue(model.filteredResults.allSatisfy { $0.collection == "JWST" })
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
        XCTAssertEqual(model.filteredResults[0].targetName, "M31")
    }

    func testFilterEmpty() {
        let model = makeModel()
        model.setFilter("collection", text: "")
        XCTAssertEqual(model.filteredCount, 4)
    }

    func testFilterNoMatch() {
        let model = makeModel()
        model.setFilter("collection", text: "NONEXISTENT")
        XCTAssertEqual(model.filteredCount, 0)
    }

    // MARK: - Pagination

    func testPaginationDefault() {
        let model = makeModel()
        model.rowsPerPage = 2
        XCTAssertEqual(model.paginatedResults.count, 2)
        XCTAssertEqual(model.totalPages, 2)
    }

    func testPaginationSecondPage() {
        let model = makeModel()
        model.rowsPerPage = 2
        model.currentPage = 1
        XCTAssertEqual(model.paginatedResults.count, 2)
    }

    func testPaginationAllRows() {
        let model = makeModel()
        model.rowsPerPage = 0 // all
        XCTAssertEqual(model.paginatedResults.count, 4)
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

    // MARK: - Combined Sort + Filter

    func testSortAndFilterTogether() {
        let model = makeModel()
        model.setFilter("collection", text: "JWST")
        model.toggleSort("targetname")
        let results = model.sortedResults
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].targetName, "M101") // M101 < M31 alphabetically
        XCTAssertEqual(results[1].targetName, "M31")
    }
}
