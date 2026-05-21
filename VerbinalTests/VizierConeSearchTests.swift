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
    }

    private func makeTool(spy: Spy, rows: [[String]] = []) -> VizierConeSearchTool {
        VizierConeSearchTool(search: { cat, ra, dec, rad, raCol, decCol, max in
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
}
