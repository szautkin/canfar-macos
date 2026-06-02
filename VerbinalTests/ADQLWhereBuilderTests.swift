// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Tests for the ADQL WHERE-clause builders that turn advanced-search form
/// state into raw ADQL. These pin SQL-injection escaping, wildcard expansion,
/// lowercasing/trimming, and single-vs-OR clause shape so search queries
/// stay correct and safe.
final class ADQLWhereBuilderTests: XCTestCase {

    // A real enumerated utype -> column mapping used throughout.
    // "Observation.collection" maps to "Observation.collection".
    private let collectionUtype = "Observation.collection"

    // MARK: - DataTrainBuilder

    func testDataTrainSingleValueEmitsEquals() {
        let clauses = DataTrainBuilder.buildWhere(
            selections: [collectionUtype: ["CFHT"]]
        )
        XCTAssertEqual(clauses, ["Observation.collection = 'CFHT'"])
    }

    func testDataTrainMultipleValuesEmitsParenthesizedOr() {
        let clauses = DataTrainBuilder.buildWhere(
            selections: [collectionUtype: ["a", "b"]]
        )
        XCTAssertEqual(
            clauses,
            ["( Observation.collection = 'a' OR Observation.collection = 'b' )"]
        )
    }

    func testDataTrainThreeValuesJoinWithOr() {
        let clauses = DataTrainBuilder.buildWhere(
            selections: [collectionUtype: ["a", "b", "c"]]
        )
        XCTAssertEqual(
            clauses,
            ["( Observation.collection = 'a' OR Observation.collection = 'b' OR Observation.collection = 'c' )"]
        )
    }

    func testDataTrainUnknownUtypeSkipped() {
        let clauses = DataTrainBuilder.buildWhere(
            selections: ["Not.A.Real.Utype": ["x"]]
        )
        XCTAssertTrue(clauses.isEmpty)
    }

    func testDataTrainEmptyValueListYieldsNoClause() {
        let clauses = DataTrainBuilder.buildWhere(
            selections: [collectionUtype: []]
        )
        XCTAssertTrue(clauses.isEmpty)
    }

    func testDataTrainSingleQuoteIsDoubled() {
        let clauses = DataTrainBuilder.buildWhere(
            selections: [collectionUtype: ["don't"]]
        )
        XCTAssertEqual(clauses, ["Observation.collection = 'don''t'"])
    }

    func testDataTrainSingleQuoteDoubledInOrList() {
        let clauses = DataTrainBuilder.buildWhere(
            selections: [collectionUtype: ["O'Brien", "plain"]]
        )
        XCTAssertEqual(
            clauses,
            ["( Observation.collection = 'O''Brien' OR Observation.collection = 'plain' )"]
        )
    }

    /// Each utype this builder accepts must map exactly to its ADQL column,
    /// so the emitted clause uses the column from `ADQL.dataTrainObservationColumns`.
    func testDataTrainUtypeMapsToConfiguredColumn() {
        for (utype, column) in ADQL.dataTrainObservationColumns {
            let clauses = DataTrainBuilder.buildWhere(selections: [utype: ["v"]])
            XCTAssertEqual(clauses, ["\(column) = 'v'"], "utype \(utype)")
        }
    }

    // MARK: - escapeSql

    func testEscapeSqlDoublesSingleQuotes() {
        XCTAssertEqual(escapeSql("don't"), "don''t")
        XCTAssertEqual(escapeSql("''"), "''''")
        XCTAssertEqual(escapeSql("none here"), "none here")
    }

    // MARK: - ObservationBuilder (wild fields)

    func testObservationWildFieldEmitsLowercasedLike() {
        let utype = "Observation.proposal.pi" // a wild text field
        let column = ADQL.observationTAPColumns[utype]!
        let clauses = ObservationBuilder.buildWhere(values: [utype: "O'Brien"])
        XCTAssertEqual(clauses, ["lower(\(column)) LIKE '%o''brien%'"])
    }

    func testObservationWildFieldLowercasesValue() {
        let utype = "Observation.proposal.id"
        let column = ADQL.observationTAPColumns[utype]!
        let clauses = ObservationBuilder.buildWhere(values: [utype: "MixedCase"])
        XCTAssertEqual(clauses, ["lower(\(column)) LIKE '%mixedcase%'"])
    }

    // MARK: - ObservationBuilder (exact fields)

    func testObservationExactFieldWithoutWildcardEmitsEquals() {
        let utype = "Observation.observationID" // the exact text field
        let column = ADQL.observationTAPColumns[utype]!
        let clauses = ObservationBuilder.buildWhere(values: [utype: "ABC123"])
        XCTAssertEqual(clauses, ["lower(\(column)) = 'abc123'"])
    }

    func testObservationExactFieldWithWildcardExpandsStarToPercent() {
        let utype = "Observation.observationID"
        let column = ADQL.observationTAPColumns[utype]!
        let clauses = ObservationBuilder.buildWhere(values: [utype: "abc*def"])
        XCTAssertEqual(clauses, ["lower(\(column)) LIKE 'abc%def'"])
    }

    func testObservationExactFieldTrailingWildcard() {
        let utype = "Observation.observationID"
        let column = ADQL.observationTAPColumns[utype]!
        let clauses = ObservationBuilder.buildWhere(values: [utype: "GN-2020A*"])
        XCTAssertEqual(clauses, ["lower(\(column)) LIKE 'gn-2020a%'"])
    }

    // MARK: - ObservationBuilder (escaping / trimming / skipping)

    func testObservationSingleQuoteEscaped() {
        let utype = "Observation.observationID"
        let column = ADQL.observationTAPColumns[utype]!
        let clauses = ObservationBuilder.buildWhere(values: [utype: "o'x"])
        XCTAssertEqual(clauses, ["lower(\(column)) = 'o''x'"])
    }

    func testObservationLeadingTrailingWhitespaceTrimmed() {
        let utype = "Observation.observationID"
        let column = ADQL.observationTAPColumns[utype]!
        let clauses = ObservationBuilder.buildWhere(values: [utype: "  ABC  "])
        XCTAssertEqual(clauses, ["lower(\(column)) = 'abc'"])
    }

    func testObservationEmptyValueSkipped() {
        let clauses = ObservationBuilder.buildWhere(
            values: ["Observation.observationID": ""]
        )
        XCTAssertTrue(clauses.isEmpty)
    }

    func testObservationWhitespaceOnlyValueSkipped() {
        let clauses = ObservationBuilder.buildWhere(
            values: ["Observation.observationID": "   "]
        )
        XCTAssertTrue(clauses.isEmpty)
    }

    func testObservationUnknownUtypeSkipped() {
        let clauses = ObservationBuilder.buildWhere(
            values: ["Not.A.Real.Utype": "value"]
        )
        XCTAssertTrue(clauses.isEmpty)
    }
}
