// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ResultExportServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SearchResultColumns.clearPersistedVisibility()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        // Clean up the stable temp file the server-side path stages so tests
        // don't leak across runs.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("results.xml")
        try? FileManager.default.removeItem(at: stable)
        super.tearDown()
    }

    // MARK: - Server-side

    func testServerSideSuccessReturnsStagedTempURL() async throws {
        let payload = Data("<VOTABLE/>".utf8)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, payload)
        }

        let url = URL(string: "https://example.test/tap/sync?FORMAT=votable")!
        let staged = try await ResultExportService.exportServerSide(
            url: url,
            ext: "xml",
            session: MockURLProtocol.mockSession()
        )
        defer { try? FileManager.default.removeItem(at: staged) }

        // Staged at a stable temp URL named results.xml.
        XCTAssertEqual(staged.lastPathComponent, "results.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        let written = try Data(contentsOf: staged)
        XCTAssertEqual(written, payload)
    }

    func testServerSideNon200ThrowsAndCleansUpTempFile() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("error".utf8))
        }

        let url = URL(string: "https://example.test/tap/sync")!
        do {
            _ = try await ResultExportService.exportServerSide(
                url: url,
                ext: "xml",
                session: MockURLProtocol.mockSession()
            )
            XCTFail("Expected a non-200 response to throw")
        } catch let error as ResultExportService.ExportError {
            guard case .httpStatus(let code) = error else {
                return XCTFail("Expected .httpStatus, got \(error)")
            }
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // No stable temp file left behind on the failure path.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("results.xml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stable.path))
    }

    func testMakeExportSessionAppliesTimeouts() {
        let session = ResultExportService.makeExportSession()
        defer { session.invalidateAndCancel() }
        XCTAssertEqual(
            session.configuration.timeoutIntervalForRequest,
            ResultExportService.Timeout.request
        )
        XCTAssertEqual(
            session.configuration.timeoutIntervalForResource,
            ResultExportService.Timeout.resource
        )
    }

    // MARK: - Client-side

    @MainActor
    private func fixtureModel() -> SearchResultsModel {
        let model = SearchResultsModel(unitStore: InMemoryColumnUnitStore())
        let headers = ["\"Collection\"", "\"Target Name\"", "\"Cal. Lev.\""]
        let rows = [
            ["JWST", "M31", "2"],
            ["HST", "NGC", "1"],
        ]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 10)
        return model
    }

    @MainActor
    func testClientSideWritesRowsAndColumnsToTempURL() throws {
        let model = fixtureModel()

        let staged = try ResultExportService.exportClientSide(
            rows: model.fullFilteredSortedResults,
            columns: model.columns,
            format: .csv
        )
        defer { try? FileManager.default.removeItem(at: staged) }

        XCTAssertEqual(staged.lastPathComponent, "results.csv")
        let content = try String(contentsOf: staged, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3) // header + 2 rows
        XCTAssertTrue(content.contains("Collection"))
        XCTAssertTrue(content.contains("JWST"))
        XCTAssertTrue(content.contains("HST"))
    }

    @MainActor
    func testClientSideEmptyRowsThrowsNoRows() {
        let model = SearchResultsModel(unitStore: InMemoryColumnUnitStore())
        // No rows loaded.
        do {
            _ = try ResultExportService.exportClientSide(
                rows: model.fullFilteredSortedResults,
                columns: model.columns,
                format: .csv
            )
            XCTFail("Expected empty rows to throw")
        } catch let error as ResultExportService.ExportError {
            guard case .noRows = error else {
                return XCTFail("Expected .noRows, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // No temp file left behind for the empty-rows error.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("results.csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    @MainActor
    func testClientSideNoVisibleColumnsThrowsAndCleansUp() {
        let model = fixtureModel()
        for col in model.columns.list {
            model.columns.setVisibility(id: col.id, visible: false)
        }

        do {
            _ = try ResultExportService.exportClientSide(
                rows: model.fullFilteredSortedResults,
                columns: model.columns,
                format: .csv
            )
            XCTFail("Expected no-visible-columns to throw")
        } catch {
            // ClientExporter.ExportError.noVisibleColumns propagates.
        }

        // Temp file removed on the failure branch.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("results.csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }
}
