// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Coverage for `VizierConeSearchTool.handle` — the shaping layer
// that takes the agent's (catalogue, ra, dec, radiusArcsec) call
// and produces the (catalogue, raDeg, decDeg, radiusDeg, raCol,
// decCol, maxRec) shape the underlying TAP service consumes. The
// real VizieR fetch happens against CDS so we don't exercise it
// here; the closure-injection pattern lets us stub the network
// surface and verify the boundary logic in isolation.

import XCTest
import VerbinalKit
@testable import Verbinal

final class VizierConeSearchTests: XCTestCase {

    /// Records the arguments the tool passed to the underlying
    /// TAP closure, so we can assert the shape.
    private final class Spy: @unchecked Sendable {
        var lastCatalogue: String = ""
        var lastRaDeg: Double = 0
        var lastDecDeg: Double = 0
        var lastRadiusDeg: Double = 0
        var lastRaCol: String = ""
        var lastDecCol: String = ""
        var lastMaxRec: Int = 0
        var lastColumns: [String]?
    }

    private func makeTool(spy: Spy, rows: [[String]] = []) -> VizierConeSearchTool {
        VizierConeSearchTool(search: { cat, ra, dec, rad, raCol, decCol, columns, max in
            spy.lastColumns = columns
            spy.lastCatalogue = cat
            spy.lastRaDeg = ra
            spy.lastDecDeg = dec
            spy.lastRadiusDeg = rad
            spy.lastRaCol = raCol
            spy.lastDecCol = decCol
            spy.lastMaxRec = max
            return (headers: ["RAJ2000", "DEJ2000"], rows: rows)
        })
    }

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 8)
        )
    }

    func testRadiusArcsecConvertsToDegrees() async throws {
        let spy = Spy()
        let tool = makeTool(spy: spy)
        _ = try await tool.handle(
            .init(catalogue: "V/97/catalog", raDeg: 298.444,
                  decDeg: 18.779, radiusArcsec: 300,
                  raColumn: nil, decColumn: nil, maxRec: nil),
            context: ctx()
        )
        XCTAssertEqual(spy.lastRadiusDeg, 300.0 / 3600.0, accuracy: 1e-9,
            "300 arcsec must convert to 1/12 degree exactly")
    }

    func testDefaultColumnNamesAreRAJ2000_DEJ2000() async throws {
        let spy = Spy()
        let tool = makeTool(spy: spy)
        _ = try await tool.handle(
            .init(catalogue: "V/97/catalog", raDeg: 0, decDeg: 0,
                  radiusArcsec: 60, raColumn: nil, decColumn: nil, maxRec: nil),
            context: ctx()
        )
        XCTAssertEqual(spy.lastRaCol, "RAJ2000")
        XCTAssertEqual(spy.lastDecCol, "DEJ2000")
    }

    func testOverridingColumnNamesIsRespected() async throws {
        let spy = Spy()
        let tool = makeTool(spy: spy)
        _ = try await tool.handle(
            .init(catalogue: "I/355/gaiadr3",
                  raDeg: 0, decDeg: 0, radiusArcsec: 60,
                  raColumn: "ra", decColumn: "dec", maxRec: nil),
            context: ctx()
        )
        XCTAssertEqual(spy.lastRaCol, "ra",
            "caller-supplied raColumn must override default; Gaia DR3 uses `ra`/`dec`, not RAJ2000")
        XCTAssertEqual(spy.lastDecCol, "dec")
    }

    func testDefaultMaxRecIs500() async throws {
        let spy = Spy()
        let tool = makeTool(spy: spy)
        _ = try await tool.handle(
            .init(catalogue: "V/97/catalog", raDeg: 0, decDeg: 0,
                  radiusArcsec: 60, raColumn: nil, decColumn: nil, maxRec: nil),
            context: ctx()
        )
        XCTAssertEqual(spy.lastMaxRec, 500)
    }

    func testProbablyTruncatedWhenRowCountHitsCap() async throws {
        let spy = Spy()
        // 5 rows at maxRec=5 → truncation flag should fire.
        let tool = makeTool(
            spy: spy,
            rows: Array(repeating: ["0", "0"], count: 5)
        )
        let out = try await tool.handle(
            .init(catalogue: "V/97/catalog", raDeg: 0, decDeg: 0,
                  radiusArcsec: 60, raColumn: nil, decColumn: nil, maxRec: 5),
            context: ctx()
        )
        XCTAssertTrue(out.probablyTruncated,
            "rowCount == maxRec must set probablyTruncated so callers know to widen the query")
    }

    func testProbablyTruncatedFalseWhenUnderCap() async throws {
        let spy = Spy()
        let tool = makeTool(
            spy: spy,
            rows: Array(repeating: ["0", "0"], count: 3)
        )
        let out = try await tool.handle(
            .init(catalogue: "V/97/catalog", raDeg: 0, decDeg: 0,
                  radiusArcsec: 60, raColumn: nil, decColumn: nil, maxRec: 10),
            context: ctx()
        )
        XCTAssertFalse(out.probablyTruncated)
    }

    func testGaiaCatalogueDefaultsToICRSColumns() async throws {
        let spy = Spy()
        let tool = makeTool(spy: spy)
        _ = try await tool.handle(
            .init(catalogue: "I/355/gaiadr3", raDeg: 10.68, decDeg: 41.27,
                  radiusArcsec: 30, raColumn: nil, decColumn: nil, maxRec: nil),
            context: ctx()
        )
        XCTAssertEqual(spy.lastRaCol, "RA_ICRS")
        XCTAssertEqual(spy.lastDecCol, "DE_ICRS")
    }

    func testVizierConeADQLOmitsSelectTop() {
        let adql = TAPClient.vizierConeADQL(
            catalogue: "I/355/gaiadr3",
            raDeg: 10.68, decDeg: 41.27, radiusDeg: 0.01,
            raColumn: "RA_ICRS", decColumn: "DE_ICRS")
        XCTAssertFalse(adql.uppercased().contains("SELECT TOP"),
                       "VizieR TAP 1.1 rejects SELECT TOP when MAXREC is also posted")
        XCTAssertTrue(adql.contains("CIRCLE('ICRS'"))
        // Plan 15 R4 (QA M9): nearest first, with the separation, so MAXREC keeps the nearest.
        XCTAssertTrue(adql.contains("AS sep_arcsec"))
        XCTAssertTrue(adql.hasSuffix("ORDER BY sep_arcsec"))
        XCTAssertTrue(adql.hasPrefix("SELECT *,"))
        let chosen = TAPClient.vizierConeADQL(catalogue: "I/355/gaiadr3", raDeg: 10.68, decDeg: 41.27, radiusDeg: 0.01,
                                              raColumn: "RA_ICRS", decColumn: "DE_ICRS",
                                              columns: ["Source", "Gmag", "BP-RP"])
        XCTAssertTrue(chosen.hasPrefix("SELECT Source, Gmag, \"BP-RP\","), chosen)
        XCTAssertEqual(TAPClient.vizierDefaultPositionColumns(catalogue: "I/355/gaiadr3").ra, "RA_ICRS")
    }

    func testTAPSyncPOSTIncludesRequestDoQuery() {
        let fields = TAPClient.tapPOSTFields(adql: "SELECT 1", maxRec: 10)
        XCTAssertEqual(fields["REQUEST"], "doQuery",
                       "VizieR TAP 1.1 returns HTTP 400 unless REQUEST=doQuery is posted")
        XCTAssertEqual(fields["LANG"], "ADQL")
        XCTAssertEqual(fields["MAXREC"], "10")
        XCTAssertEqual(fields["QUERY"], "SELECT 1")
    }

    // MARK: - Plan 36 2.6: the reason, not the XML

    private let refusal = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VOTABLE version="1.4" xmlns="http://www.ivoa.net/xml/VOTable/v1.3">
      <RESOURCE type="results">
        <INFO name="QUERY_STATUS" value="ERROR">Incorrect ADQL query: 2 unresolved identifiers: RAJ2000 [l.1 c.8 - l.1 c.15], DEJ2000 [l.1 c.17 - l.1 c.24]! Cause: Unknown column &quot;RAJ2000&quot;</INFO>
      </RESOURCE>
    </VOTABLE>
    """

    func testAServicesReasonIsReadFromItsVOTable() {
        XCTAssertEqual(TAPClient.errorReason(refusal),
                       "Incorrect ADQL query: 2 unresolved identifiers: RAJ2000 [l.1 c.8 - l.1 c.15], DEJ2000 [l.1 c.17 - l.1 c.24]! Cause: Unknown column \"RAJ2000\"")
        XCTAssertEqual(TAPClient.errorReason("<html><body><h1>Bad request</h1> no table</body></html>"), "Bad request no table")
        XCTAssertEqual(TAPClient.errorReason(""), "no reason given")
    }

    func testARefusedQuerySaysWhyFirstAndNamesTheMissingColumns() async throws {
        let body = refusal
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        do {
            _ = try await TAPClient(session: MockURLProtocol.mockSession())
                .vizierConeSearch(catalogue: "V/97/variabls", raDeg: 10.68, decDeg: 41.27, radiusDeg: 0.01)
            XCTFail("refused")
        } catch {
            let message = ToolFailureReason.backendError("vizier_cone_search: \(error.localizedDescription)").description
            XCTAssertTrue(message.contains("refused the query: TAP query failed (HTTP 400): Incorrect ADQL query"), message)
            XCTAssertTrue(message.contains("The catalogue has no RAJ2000 column"), message)
            XCTAssertFalse(message.contains("<?xml"), message)
        }
    }
}
