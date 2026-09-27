// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
}
