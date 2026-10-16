// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

final class ADQLValidatorTests: XCTestCase {

    /// A CADC-shaped slice of TAP_SCHEMA.
    private let schema: TapSchema = {
        func col(_ n: String) -> TapSchema.Column { .init(name: n, datatype: "char", description: "", unit: "", ucd: "") }
        return TapSchema(
            tables: [
                .init(name: "caom2.Observation", description: "", columns: ["obsID", "observationID", "collection"].map(col)),
                .init(name: "caom2.Plane", description: "", columns: ["obsID", "planeID", "calibrationLevel"].map(col)),
            ],
            keys: [])
    }()

    private func problems(_ adql: String, schema: TapSchema? = nil) -> [ADQLProblem] {
        ADQLValidator.problems(in: adql, schema: schema ?? self.schema)
    }

    func testAGoodJoinWithAliasesHasNoProblems() {
        XCTAssertEqual(problems("SELECT TOP 10 o.observationID FROM caom2.Observation AS o JOIN caom2.Plane AS p ON p.obsID = o.obsID WHERE p.calibrationLevel = 2"), [])
    }

    /// CADC: "Column [obsID] is ambiguous".
    func testABareTableQualifierOnASharedColumnIsAmbiguous() throws {
        let adql = "SELECT Observation.observationID FROM caom2.Observation JOIN caom2.Plane ON Plane.obsID = Observation.obsID"
        let found = problems(adql)
        XCTAssertEqual(found.count, 2)
        let first = try XCTUnwrap(found.first)
        XCTAssertEqual(first.text(in: adql), "Plane.obsID")
        XCTAssertEqual(first.fix, "caom2.Plane.obsID")
        // A column only one table has may be qualified by the bare name.
        XCTAssertFalse(found.contains { $0.text(in: adql) == "Observation.observationID" })
    }

    func testAnUnknownColumnSuggestsTheOneThatExists() throws {
        let adql = "SELECT p.calibrationlev FROM caom2.Plane AS p"
        let problem = try XCTUnwrap(problems(adql).first)
        XCTAssertEqual(problem.message, "caom2.Plane has no column \"calibrationlev\"")
        XCTAssertEqual(problem.fix, "p.calibrationLevel")
    }

    func testAnUnknownTableSuggestsItsQualifiedName() throws {
        let problem = try XCTUnwrap(problems("SELECT * FROM Plane").first)
        XCTAssertEqual(problem.message, "no table \"Plane\" in this service")
        XCTAssertEqual(problem.fix, "caom2.Plane")
    }

    func testLimitIsFlaggedEvenWithoutASchema() throws {
        let adql = "SELECT * FROM caom2.Plane LIMIT 5"
        let problem = try XCTUnwrap(ADQLValidator.problems(in: adql, schema: nil).first)
        XCTAssertEqual(problem.text(in: adql), "LIMIT 5")
        XCTAssertEqual(problem.fix, "SELECT TOP 5")
    }

    /// Literals and comments are not code.
    func testLiteralsAndCommentsAreIgnored() {
        XCTAssertEqual(problems("SELECT o.obsID FROM caom2.Observation AS o WHERE o.collection = 'p.nothing LIMIT 3' -- p.nope"), [])
    }

    /// Anything it cannot resolve is left alone.
    func testSubqueriesAndFunctionsAreNotGuessedAt() {
        XCTAssertEqual(problems("SELECT t.x FROM (SELECT obsID AS x FROM caom2.Plane) AS t"), [])
        XCTAssertEqual(problems("SELECT COUNT(*) FROM caom2.Plane"), [])
    }

    func testNoSchemaMeansOnlyDialectRules() {
        XCTAssertEqual(ADQLValidator.problems(in: "SELECT q.x FROM nowhere.T AS q", schema: nil), [])
    }

    // MARK: - Schema assembly

    func testSchemaIsReadByFieldNameInAnyOrderOrCase() {
        let schema = TapSchema.build(
            tables: (headers: ["description", "TABLE_NAME"], rows: [["Planes", "caom2.Plane"]]),
            columns: (headers: ["column_name", "table_name", "unit", "datatype"], rows: [["obsID", "caom2.Plane", "", "char"],
                                                                                         ["x", "orphan.T", "deg", "double"]]),
            keys: (headers: [], rows: []))
        XCTAssertEqual(schema.table("CAOM2.PLANE")?.description, "Planes")
        XCTAssertEqual(schema.table("caom2.Plane")?.columns.map(\.name), ["obsID"])
        XCTAssertEqual(schema.table("orphan.T")?.column("X")?.unit, "deg", "a column of an unlisted table is kept")
    }

    @MainActor
    func testTheSchemaIsFetchedOnceAndCachedForAnHour() async throws {
        let calls = Locked(0)
        let clock = Locked(Date(timeIntervalSince1970: 0))
        let service = TapSchemaService(
            query: { adql, _ in
                calls.increment()
                return adql.contains("TAP_SCHEMA.tables")
                    ? (headers: ["table_name", "description"], rows: [["caom2.Plane", ""]])
                    : (headers: [], rows: [])
            },
            now: { clock.value })
        XCTAssertNil(service.cached)
        _ = try await service.schema()
        let perFetch = calls.value
        _ = try await service.schema()
        XCTAssertEqual(calls.value, perFetch, "served from the cache")

        clock.set(Date(timeIntervalSince1970: 3599))
        XCTAssertNotNil(service.cached)
        clock.set(Date(timeIntervalSince1970: 3601))
        XCTAssertNil(service.cached, "an hour old is stale")
        _ = try await service.schema()
        XCTAssertEqual(calls.value, 2 * perFetch, "fetched again")
    }

    // MARK: - A bare column two joined tables share (plan 15 R2, QA M16)

    func testABareSharedColumnInAJoinIsAmbiguous() throws {
        let adql = "SELECT TOP 5 obsID FROM caom2.Plane AS p JOIN caom2.Observation AS o ON p.obsID = o.obsID"
        let found = problems(adql)
        let problem = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(problem.text(in: adql), "obsID")
        XCTAssertEqual(problem.kind, .ambiguous(reference: "obsID", column: "obsID", tables: ["caom2.Plane", "caom2.Observation"]))
    }

    // MARK: - A bare column no table has (plan 39, QA 2026-10-15 4.7)

    func testABareColumnTheTableDoesNotHaveIsUnknown() throws {
        let adql = "SELECT TOP 5 calibrationlev FROM caom2.Plane"
        let problem = try XCTUnwrap(problems(adql).first)
        XCTAssertEqual(problems(adql).count, 1)
        XCTAssertEqual(problem.text(in: adql), "calibrationlev")
        XCTAssertEqual(problem.message, "caom2.Plane has no column \"calibrationlev\"")
        XCTAssertEqual(problem.fix, "calibrationLevel")
    }

    func testABareColumnNoTableHasIsUnknownInWhereAndInAJoin() {
        XCTAssertEqual(problems("SELECT planeID FROM caom2.Plane AS p WHERE nosuch > 1").map(\.message),
                       ["caom2.Plane has no column \"nosuch\""])
        XCTAssertEqual(problems("SELECT TOP 5 nosuch FROM caom2.Plane AS p JOIN caom2.Observation AS o ON p.obsID = o.obsID").map(\.message),
                       ["no table here has a column \"nosuch\""])
    }

    /// A table whose columns are not listed cannot say what it lacks.
    func testATableWithoutItsColumnsIsNotJudged() {
        let bare = TapSchema(tables: [.init(name: "ivoa.ObsCore", description: "", columns: [])], keys: [])
        XCTAssertEqual(problems("SELECT s_ra FROM ivoa.ObsCore", schema: bare), [])
    }

    /// The check refuses the query — from the editor, an assistant or a
    /// saved query — so a mark on a good one stops it running. Every one of
    /// these runs on CADC.
    func testWhatIsNotABareColumnIsLeftAlone() {
        for adql in [
            "SELECT TOP 10 * FROM caom2.Plane",
            "SELECT COUNT(*) AS n FROM caom2.Plane",
            "SELECT DISTINCT calibrationLevel FROM caom2.Plane ORDER BY calibrationLevel DESC",
            "SELECT CAST(calibrationLevel AS DOUBLE PRECISION) AS level FROM caom2.Plane ORDER BY level",
            "SELECT planeID p_id, COUNT(*) n FROM caom2.Plane GROUP BY planeID HAVING COUNT(*) > 1 ORDER BY n",
            "SELECT Plane.* FROM caom2.Plane AS Plane",
            "SELECT planeID FROM caom2.Plane WHERE calibrationLevel IS NOT NULL AND calibrationLevel BETWEEN 1 AND 3",
            "select planeid from caom2.plane where calibrationlevel in (1, 2) order by planeid asc",
            "SELECT CASE WHEN calibrationLevel > 2 THEN 'high' ELSE 'low' END AS grade FROM caom2.Plane",
            "SELECT TOP 5 obsID FROM caom2.Plane WHERE 1 = CONTAINS(POINT('ICRS', 10, 20), CIRCLE('ICRS', 10, 20, 1))",
            "SELECT planeID AS \"Plane ID\", calibrationLevel AS \"Cal. Lev.\" FROM caom2.Plane ORDER BY \"Cal. Lev.\"",
            "SELECT \"planeID\" FROM caom2.Plane",
            "SELECT planeID FROM caom2.Plane WHERE obsID = 'nosuch AND other' -- nosuch",
            "SELECT planeID FROM caom2.Plane /* nosuch */",
            "SELECT planeID FROM caom2.Plane WHERE obsID IN (SELECT obsID FROM caom2.Observation WHERE nosuch = 1)",
            "SELECT TOP 5 p.planeID FROM caom2.Plane AS p JOIN caom2.Observation AS o USING (obsID)",
            "SELECT 'x' AS label, 1 one FROM caom2.Plane",
        ] {
            XCTAssertEqual(problems(adql), [], adql)
        }
    }

    /// The query the search form writes is never refused by the check: its
    /// names are quoted (`AS "Cal. Lev."`), its columns written with their
    /// table, its frames in literals.
    @MainActor
    func testTheSearchFormsQueryPassesTheCheck() throws {
        let state = SearchFormState()
        state.target = "M31"
        state.observationID = "ia5q06010"
        state.piName = "Abraham"
        state.proposalID = "1234"
        state.proposalTitle = "galaxies"
        state.proposalKeywords = "dust"
        state.publicOnly = true
        state.intent = .science
        state.searchRadius = "0.1"
        state.pixelScale = "0.5"
        state.observationDate = "2020-01-01"
        state.integrationTime = "100"
        state.timeSpan = "1"
        state.spectralCoverage = "500nm"
        state.spectralSampling = "1nm"
        state.resolvingPower = "1000"
        state.bandpassWidth = "10nm"
        state.restFrameEnergy = "21cm"
        state.selectedBands = ["Optical"]
        state.selectedCollections = ["JWST", "HST"]
        state.selectedInstruments = ["NIRSpec"]
        state.selectedFilters = ["F200W"]
        state.selectedCalLevels = ["2"]
        state.selectedDataTypes = ["image"]
        state.selectedObsTypes = ["OBJECT"]
        for coordinates in [nil, (ra: "10.68", dec: "41.27")] as [(ra: String, dec: String)?] {
            let adql = ADQLBuilder.buildQuery(formState: state, resolverCoords: coordinates)
            // A schema with every column the query names, as CADC's has.
            var columns: [String: Set<String>] = [:]
            let pattern = try NSRegularExpression(pattern: #"\b(Plane|Observation)\.([A-Za-z_][A-Za-z0-9_]*)"#)
            for match in pattern.matches(in: adql, range: NSRange(adql.startIndex..., in: adql)) {
                let table = (adql as NSString).substring(with: match.range(at: 1))
                columns["caom2.\(table)", default: []].insert((adql as NSString).substring(with: match.range(at: 2)))
            }
            let schema = TapSchema(tables: columns.keys.sorted().map { table in
                .init(name: table, description: "", columns: columns[table, default: []].sorted().map {
                    .init(name: $0, datatype: "char", description: "", unit: "", ucd: "")
                })
            }, keys: [])
            XCTAssertEqual(problems(adql, schema: schema).map(\.summary), [], adql)
        }
    }

    /// Only what it is sure of: these all run on CADC.
    func testABareColumnItCannotBeSureOfIsLeftAlone() {
        for adql in [
            "SELECT TOP 5 calibrationLevel FROM caom2.Plane AS p JOIN caom2.Observation AS o ON p.obsID = o.obsID",
            "SELECT TOP 5 obsID FROM caom2.Plane",
            "SELECT TOP 5 o.obsID AS obsID FROM caom2.Plane AS p JOIN caom2.Observation AS o ON p.obsID = o.obsID ORDER BY obsID",
            "SELECT TOP 5 p.planeID FROM caom2.Plane AS p JOIN caom2.Observation AS o USING (obsID)",
            "SELECT TOP 5 p.planeID FROM caom2.Plane AS p WHERE p.obsID IN (SELECT obsID FROM caom2.Observation AS o WHERE o.collection = 'JWST')",
            "SELECT TOP 5 COUNT(p.planeID) FROM caom2.Plane AS p JOIN caom2.Observation AS o ON p.obsID = o.obsID",
        ] {
            XCTAssertEqual(problems(adql), [], adql)
        }
    }
}

/// On screen (plan 39 step 3): the ADQL editor lists the mistake under the
/// query, as the person reads it, with the schema it fetched.
@MainActor
final class ADQLEditorOnScreenTests: XCTestCase {
    func testTheEditorListsABareColumnTheTableDoesNotHave() async throws {
        try await AXReadable.require()
        MockURLProtocol.requestHandler = { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let csv = if body.contains("TAP_SCHEMA.tables") {
                "table_name,description\ncaom2.Plane,Planes\n"
            } else if body.contains("TAP_SCHEMA.columns") {
                "table_name,column_name,datatype,description,unit,ucd\ncaom2.Plane,calibrationLevel,int,,,\ncaom2.Plane,planeID,char,,,\n"
            } else {
                "from_table,target_table,from_column,target_column,description\n"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/csv"])!
            return (response, Data(csv.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let model = SearchFormModel(tapClient: TAPClient(session: MockURLProtocol.mockSession()))
        _ = try await model.tapSchema.schema()
        model.resultsModel.adqlQuery = "SELECT TOP 5 calibrationlev FROM caom2.Plane"

        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ADQLEditorView(searchModel: model).uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "search.adql" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(700))
        let snapshot = source.snapshot()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber }, "the window is listed")
        let names = snapshot.elements(in: ref.index).compactMap(\.name)
        XCTAssertTrue(names.contains { $0.hasPrefix("caom2.Plane has no column \"calibrationlev\"") }, "\(names)")
    }
}
