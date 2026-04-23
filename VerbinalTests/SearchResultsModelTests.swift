// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class SearchResultsModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset persisted column-visibility overrides so tests don't leak state
        // between runs or from user defaults.
        SearchResultColumns.clearPersistedVisibility()
    }

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
        XCTAssertEqual(model.columns.list[0].label, "Collection")
        XCTAssertEqual(model.columns.list[1].label, "Target Name")
        XCTAssertEqual(model.columns.list[2].label, "RA (J2000.0)")
        XCTAssertEqual(model.columns.list[3].label, "Cal. Lev.")
    }

    func testLoadResultsColumnIdsAreCleaned() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        XCTAssertEqual(model.columns.list[0].id, "collection")
        XCTAssertEqual(model.columns.list[1].id, "targetname")
        XCTAssertEqual(model.columns.list[2].id, "ra(j20000)")
        XCTAssertEqual(model.columns.list[3].id, "callev")
    }

    func testLoadResultsPopulatesRows() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        XCTAssertEqual(model.results.count, 2)
        let cols = model.columns
        XCTAssertEqual(cols.value(in: model.results[0], forID: "collection"), "JWST")
        XCTAssertEqual(cols.value(in: model.results[0], forID: "targetname"), "M31")
        XCTAssertEqual(cols.value(in: model.results[0], forID: "ra(j20000)"), "10.68471")
        XCTAssertEqual(cols.value(in: model.results[1], forID: "collection"), "HST")
    }

    func testTotalRowsMatchesCount() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        XCTAssertEqual(model.totalRows, 2)
    }

    // MARK: - Stable row id

    func testResultIDPrefersObsId() {
        let model = makeModel()
        let headers = ["\"Collection\"", "\"obsID\"", "\"Target Name\""]
        let rows = [["JWST", "obs-123", "M31"]]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 1)
        XCTAssertEqual(model.results[0].id, "obs-123")
    }

    func testResultIDFallsBackToSyntheticWhenNoObsId() {
        let model = makeModel()
        let headers = ["\"Collection\"", "\"Target Name\""]
        let rows = [["JWST", "M31"]]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 1)
        XCTAssertTrue(model.results[0].id.hasPrefix("row_"))
    }

    // MARK: - Duplicate header disambiguation

    func testDuplicateCleanedHeadersAreDisambiguated() {
        let model = makeModel()
        // "Time (s)" and "Time.s" both normalize to "times"
        let headers = ["\"Time (s)\"", "\"Time.s\""]
        let rows = [["10", "20"]]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 1)
        let ids = model.columns.list.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "Duplicate cleaned ids should be disambiguated")
    }

    // MARK: - Max Record Reached

    func testMaxRecordReachedTrue() {
        let model = makeModel()
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

        XCTAssertTrue(model.columns.column(id: "collection")?.visible == true)
        XCTAssertTrue(model.columns.column(id: "callev")?.visible == true)
    }

    func testColumnVisibilityToggle() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        let id = model.columns.list[0].id
        let wasVisible = model.columns.list[0].visible
        model.toggleColumnVisibility(id)
        XCTAssertEqual(model.columns.list[0].visible, !wasVisible)
    }

    func testVisibleColumnsFiltersCorrectly() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        let before = model.columns.visible.count
        model.toggleColumnVisibility("collection")
        XCTAssertEqual(model.columns.visible.count, before - 1)
    }

    func testResetColumnVisibility() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT *", maxRec: 30000)

        model.toggleColumnVisibility("collection")
        model.toggleColumnVisibility("targetname")
        model.resetColumnVisibility()

        XCTAssertTrue(model.columns.column(id: "collection")?.visible == true)
        XCTAssertTrue(model.columns.column(id: "targetname")?.visible == true)
    }

    // MARK: - Export URL

    func testExportURLFormation() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "SELECT * FROM caom2.Plane", maxRec: 30000)

        let csvURL = model.exportURL(format: "csv")
        XCTAssertNotNil(csvURL)
        let urlString = csvURL!.absoluteString
        XCTAssertTrue(urlString.contains("FORMAT=csv"))
        XCTAssertTrue(urlString.contains("LANG=ADQL"))
        XCTAssertTrue(urlString.contains("argus/sync"))
    }

    func testExportURLNilWhenNoQuery() {
        let model = makeModel()
        XCTAssertNil(model.exportURL(format: "csv"))
    }

    func testHasClientSideAdjustmentsWhenFilterActive() {
        let model = makeModel()
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: "Q", maxRec: 30000)
        XCTAssertFalse(model.hasClientSideAdjustments)
        model.setFilter("collection", text: "JWST")
        XCTAssertTrue(model.hasClientSideAdjustments)
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
        XCTAssertEqual(model.displayedRows.count, 0)
    }

    // MARK: - ADQL Query Storage

    func testADQLQueryStoredOnLoad() {
        let model = makeModel()
        let query = "SELECT * FROM caom2.Plane WHERE Observation.collection = 'JWST'"
        model.loadResults(headers: sampleHeaders, rows: sampleRows, query: query, maxRec: 30000)

        XCTAssertEqual(model.adqlQuery, query)
    }
}
