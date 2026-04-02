// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class SearchResultsModelTests: XCTestCase {

    private func makeModel() -> SearchResultsModel {
        SearchResultsModel()
    }

    private let sampleHeaders = [
        "\"Collection\"", "\"Target Name\"", "\"RA (J2000.0)\"", "\"Cal. Lev.\""
    ]

    private let sampleRows = [
        ["JWST", "M31", "10.68471", "2"],
        ["HST", "NGC 1234", "150.25", "1"],
    ]

    // MARK: - Loading

    func testLoadResultsPopulatesColumns() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        XCTAssertEqual(model.columns.count, 4)
        XCTAssertEqual(model.columns[0].label, "Collection")
        XCTAssertEqual(model.columns[1].label, "Target Name")
        XCTAssertEqual(model.columns[2].label, "RA (J2000.0)")
        XCTAssertEqual(model.columns[3].label, "Cal. Lev.")
    }

    func testLoadResultsColumnIdsAreCleaned() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        XCTAssertEqual(model.columns[0].id, "collection")
        XCTAssertEqual(model.columns[1].id, "targetname")
        XCTAssertEqual(model.columns[2].id, "ra(j20000)")
        XCTAssertEqual(model.columns[3].id, "callev")
    }

    func testLoadResultsPopulatesRows() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.results[0].values["collection"], "JWST")
        XCTAssertEqual(model.results[0].values["targetname"], "M31")
        XCTAssertEqual(model.results[0].values["ra(j20000)"], "10.68471")
        XCTAssertEqual(model.results[1].values["collection"], "HST")
    }

    func testTotalRowsMatchesCount() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        XCTAssertEqual(model.totalRows, 2)
    }

    // MARK: - Max Record Reached

    func testMaxRecordReachedTrue() {
        let model = makeModel()
        // Create exactly maxRec rows
        let rows = (0..<5).map { _ in ["JWST", "M31", "10.68", "2"] }
        model.loadResults(headers: sampleHeaders, rows: rows, query: "SELECT *", maxRec: 5)

        XCTAssertTrue(model.maxRecordReached)
    }

    func testMaxRecordReachedFalse() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        XCTAssertFalse(model.maxRecordReached)
    }

    // MARK: - Column Visibility

    func testDefaultVisibleColumns() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        let collectionCol = model.columns.first { $0.id == "collection" }
        XCTAssertNotNil(collectionCol)
        XCTAssertTrue(collectionCol!.visible)

        let calLevCol = model.columns.first { $0.id == "callev" }
        XCTAssertNotNil(calLevCol)
        XCTAssertTrue(calLevCol!.visible)
    }

    func testColumnVisibilityToggle() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        let colId = model.columns[0].id
        let wasVisible = model.columns[0].visible
        model.toggleColumnVisibility(colId)
        XCTAssertEqual(model.columns[0].visible, !wasVisible)
    }

    func testVisibleColumnsFiltersCorrectly() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        // All 4 sample columns are in the default visible set
        let visibleBefore = model.visibleColumns.count
        model.toggleColumnVisibility("collection")
        XCTAssertEqual(model.visibleColumns.count, visibleBefore - 1)
    }

    // MARK: - Export URL

    func testExportURLFormation() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT * FROM caom2.Plane", maxRec: 30000)

        let csvURL = model.exportURL(format: "csv")
        XCTAssertNotNil(csvURL)
        let urlString = csvURL!.absoluteString
        XCTAssertTrue(urlString.contains("FORMAT=csv"), "URL should contain FORMAT=csv")
        XCTAssertTrue(urlString.contains("LANG=ADQL"), "URL should contain LANG=ADQL")
        XCTAssertTrue(urlString.contains("argus/sync"), "URL should point to argus/sync")
    }

    func testExportURLNilWhenNoQuery() {
        let model = makeModel()
        XCTAssertNil(model.exportURL(format: "csv"))
    }

    // MARK: - Clear

    func testClearResults() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)
        XCTAssertEqual(model.results.count, 2)

        model.clearResults()
        XCTAssertEqual(model.results.count, 0)
        XCTAssertEqual(model.columns.count, 0)
        XCTAssertEqual(model.totalRows, 0)
        XCTAssertFalse(model.maxRecordReached)
        XCTAssertEqual(model.adqlQuery, "")
    }

    // MARK: - ADQL Query Storage

    func testADQLQueryStoredOnLoad() {
        let model = makeModel()
        let query = "SELECT * FROM caom2.Plane WHERE Observation.collection = 'JWST'"
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: query, maxRec: 30000)

        XCTAssertEqual(model.adqlQuery, query)
    }
}
