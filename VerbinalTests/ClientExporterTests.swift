// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ClientExporterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SearchResultColumns.clearPersistedVisibility()
    }

    @MainActor
    private func fixtureModel() -> SearchResultsModel {
        let model = SearchResultsModel(unitStore: InMemoryColumnUnitStore())
        let headers = ["\"Collection\"", "\"Target Name\"", "\"Cal. Lev.\""]
        let rows = [
            ["JWST", "M31", "2"],
            ["HST", "NGC \"quoted\"", "1"],
            ["CFHT", "M, 51", "3"],
        ]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 10)
        return model
    }

    @MainActor
    func testWriteCSVRoundTrip() async throws {
        let model = fixtureModel()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporter-test-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try ClientExporter.write(
            rows: model.fullFilteredSortedResults,
            columns: model.columns,
            format: .csv,
            to: tempURL
        )

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 4) // header + 3 rows

        // Header row should contain the original labels.
        XCTAssertTrue(lines[0].contains("\"Collection\""))
        XCTAssertTrue(lines[0].contains("\"Target Name\""))

        // Quotes are doubled (RFC 4180).
        let hstLine = lines.first { $0.contains("HST") }!
        XCTAssertTrue(hstLine.contains("\"NGC \"\"quoted\"\"\""))

        // Commas inside fields survive via quoting.
        let cfhtLine = lines.first { $0.contains("CFHT") }!
        XCTAssertTrue(cfhtLine.contains("\"M, 51\""))
    }

    @MainActor
    func testWriteTSVStripsTabsFromValues() async throws {
        let model = SearchResultsModel(unitStore: InMemoryColumnUnitStore())
        let headers = ["\"A\"", "\"B\""]
        let rows = [["one\ttwo", "three"]]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 10)
        // Columns "a"/"b" aren't in defaultVisibleKeys — force visible for the test.
        model.columns.setVisibility(id: "a", visible: true)
        model.columns.setVisibility(id: "b", visible: true)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporter-test-\(UUID().uuidString).tsv")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try ClientExporter.write(
            rows: model.fullFilteredSortedResults,
            columns: model.columns,
            format: .tsv,
            to: tempURL
        )

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        // Tab inside value must have been replaced with a space (TSV has no escape).
        XCTAssertFalse(content.contains("one\ttwo"))
        XCTAssertTrue(content.contains("one two"))
    }

    @MainActor
    func testWriteOnlyIncludesVisibleColumns() async throws {
        let model = fixtureModel()
        model.toggleColumnVisibility("callev") // hide it

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporter-test-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try ClientExporter.write(
            rows: model.fullFilteredSortedResults,
            columns: model.columns,
            format: .csv,
            to: tempURL
        )

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertFalse(content.contains("Cal. Lev."))
        XCTAssertTrue(content.contains("Collection"))
    }

    @MainActor
    func testWriteWithNoVisibleColumnsThrows() async throws {
        let model = fixtureModel()
        for col in model.columns.list {
            model.columns.setVisibility(id: col.id, visible: false)
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporter-test-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertThrowsError(try ClientExporter.write(
            rows: model.fullFilteredSortedResults,
            columns: model.columns,
            format: .csv,
            to: tempURL
        ))
    }

    func testCSVEncodeHandlesEmbeddedQuotes() {
        let encoded = ClientExporter.encode("say \"hi\"", format: .csv)
        XCTAssertEqual(encoded, "\"say \"\"hi\"\"\"")
    }

    func testCSVEncodePlainValue() {
        let encoded = ClientExporter.encode("JWST", format: .csv)
        XCTAssertEqual(encoded, "\"JWST\"")
    }

    func testTSVEncodeNormalizesNewlines() {
        let encoded = ClientExporter.encode("line1\nline2\r\nline3", format: .tsv)
        XCTAssertEqual(encoded, "line1 line2  line3")
    }
}
