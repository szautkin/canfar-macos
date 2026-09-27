// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Copy Details and rows as TSV read the same from every screen.
@MainActor
final class CopyTextTests: XCTestCase {

    private let headers = ["\"Publisher ID\"", "\"Collection\"", "\"RA (J2000.0)\"", "\"Dec. (J2000.0)\"",
                           "\"Target Name\"", "\"Instrument\"", "\"Filter\"", "\"Cal. Lev.\"", "\"Proposal ID\"", "\"Obs. ID\""]
    private let row = ["ivo://cadc.nrc.ca/HST?x/y", "HST", "10.684708", "41.269167",
                       "M31\twith tab", "WFC3", "F814W", "2", "12345", "idj1"]

    private func model() -> SearchResultsModel {
        let model = SearchResultsModel(unitStore: InMemoryColumnUnitStore())
        model.loadResults(headers: headers, rows: [row], query: "SELECT *", maxRec: 100)
        return model
    }

    func testDetailsWriteThePositionAsSearchReadsItWithTheDegrees() throws {
        let model = model()
        let facts = model.facts(for: try XCTUnwrap(model.results.first))
        XCTAssertEqual(facts.position, "00:42:44.33 +41:16:09.0 (10.684708°, +41.269167°)")
        let text = facts.detailsText
        XCTAssertTrue(text.hasPrefix("Observation: idj1\nCollection: HST\nPublisher ID: ivo://cadc.nrc.ca/HST?x/y"), text)
        XCTAssertTrue(text.contains("Instrument: WFC3"))
        XCTAssertFalse(text.contains("Release:"), "an empty fact is left out")
        // The Search box reads the position back.
        let pair = try XCTUnwrap(SpatialBuilder.parseCoordinatePair("00:42:44.33 +41:16:09.0"))
        XCTAssertEqual(pair.ra, 10.684708, accuracy: 1e-5)
        XCTAssertEqual(pair.dec, 41.269167, accuracy: 1e-5)
    }

    func testRowsCopyAsTabSeparatedWithAHeader() throws {
        let model = model()
        let columns = Array(model.columns.visible.prefix(3))
        let tsv = model.tabSeparated(model.results, columns: columns)
        let lines = tsv.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], columns.map(\.label).joined(separator: "\t"))
        XCTAssertFalse(model.tabSeparated(model.results, columns: model.columns.visible).contains("M31\twith"),
                       "a tab inside a value would split the cell")
    }

    func testAResearchRecordGivesTheSameDetails() {
        let obs = DownloadedObservation(
            publisherID: "ivo://p", collection: "CFHT", observationID: "123", targetName: "M31",
            instrument: "MegaPrime", filter: "r", ra: "10.684708", dec: "41.269167",
            startDate: "2020-01-01", calLevel: "2", localPath: "x.fits")
        XCTAssertEqual(obs.facts.position, "00:42:44.33 +41:16:09.0 (10.684708°, +41.269167°)")
        XCTAssertTrue(obs.facts.detailsText.contains("Observation: 123"))
    }

    func testTheSearchBoxStillTakesNamesAndDecimalDegrees() {
        XCTAssertNil(SpatialBuilder.parseCoordinatePair("NGC 224"))
        XCTAssertNotNil(SpatialBuilder.parseCoordinatePair("10.68 41.27 2arcmin"))
        XCTAssertNotNil(SpatialBuilder.parseCoordinatePair("10,68 41,27"))
    }

    func testCopyToClipboardTakesExactlyOneSource() async throws {
        let tool = CopyToClipboardTool(copy: { args in (args.text ?? "", true) })
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))
        let both = await tool.invoke(arguments: Data(#"{"text":"a","publisherId":"b"}"#.utf8), context: ctx)
        guard case .failed = both else { return XCTFail("two sources must be refused") }
        let none = await tool.invoke(arguments: Data("{}".utf8), context: ctx)
        guard case .failed = none else { return XCTFail("no source must be refused") }
        let one = await tool.invoke(arguments: Data(#"{"text":"hello"}"#.utf8), context: ctx)
        guard case .data(let bytes) = one else { return XCTFail("\(one)") }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(body["copied"] as? Bool, true)
        XCTAssertEqual(body["text"] as? String, "hello")
    }
}
