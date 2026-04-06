// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ADQLBuilderTests: XCTestCase {

    func testEmptyFormProducesQualityFilter() {
        let state = SearchFormState()
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("WHERE"), "Query must have WHERE clause")
        XCTAssertTrue(query.contains("quality_flag"), "Must include quality filter")
        XCTAssertTrue(query.contains("SELECT"), "Must have SELECT")
        XCTAssertTrue(query.contains("FROM"), "Must have FROM")
    }

    func testTargetNameSearch() {
        let state = SearchFormState()
        state.target = "M31"
        state.resolver = .none
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("target_name"), "Should search by target name")
        XCTAssertTrue(query.lowercased().contains("m31"), "Should contain target")
    }

    func testResolvedTargetUsesCircle() {
        let state = SearchFormState()
        state.target = "M31"
        state.resolver = .all
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: (ra: "10.68", dec: "41.27"))
        XCTAssertTrue(query.contains("INTERSECTS"), "Resolved target should use INTERSECTS")
        XCTAssertTrue(query.contains("CIRCLE"), "Should use CIRCLE for point search")
        XCTAssertTrue(query.contains("10.68"), "Should contain resolved RA")
    }

    func testObservationIDExactMatch() {
        let state = SearchFormState()
        state.observationID = "ia5q06010"
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("observationID"), "Should search by obs ID")
        XCTAssertTrue(query.contains("ia5q06010"), "Should contain exact ID")
    }

    func testPINameWildcard() {
        let state = SearchFormState()
        state.piName = "Abraham"
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("LIKE"), "PI name should use LIKE")
        XCTAssertTrue(query.contains("%abraham%"), "Should wrap with wildcards")
    }

    func testIntentFilter() {
        let state = SearchFormState()
        state.intent = .science
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("intent = 'science'"), "Should filter by science intent")
    }

    func testPublicOnlyFilter() {
        let state = SearchFormState()
        state.publicOnly = true
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("dataRelease"), "Should filter by data release")
    }

    func testCollectionFilter() {
        let state = SearchFormState()
        state.selectedCollections = ["JWST"]
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("collection"), "Should filter by collection")
        XCTAssertTrue(query.contains("JWST"), "Should contain collection name")
    }

    func testMultipleCollectionsUseOR() {
        let state = SearchFormState()
        state.selectedCollections = ["JWST", "HST"]
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("OR"), "Multiple collections should use OR")
    }

    func testSelectColumnsPresent() {
        let state = SearchFormState()
        let query = ADQLBuilder.buildQuery(formState: state, resolverCoords: nil)
        XCTAssertTrue(query.contains("Observation.collection"), "Should select collection")
        XCTAssertTrue(query.contains("Plane.publisherID"), "Should select publisherID")
    }
}

final class CSVParserTests: XCTestCase {

    func testParseSimpleCSV() {
        let csv = "\"Name\",\"Value\"\nAlpha,1\nBeta,2\n"
        let (headers, rows) = CSVParser.parse(csv)
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0], "Alpha")
        XCTAssertEqual(rows[0][1], "1")
    }

    func testParseQuotedFields() {
        let csv = "\"A\",\"B\"\n\"hello, world\",\"test\"\n"
        let (_, rows) = CSVParser.parse(csv)
        XCTAssertEqual(rows[0][0], "hello, world")
    }

    func testParseEmptyCSV() {
        let (headers, rows) = CSVParser.parse("")
        XCTAssertEqual(headers.count, 0)
        XCTAssertEqual(rows.count, 0)
    }

    func testCleanHeader() {
        XCTAssertEqual(CSVParser.cleanHeader("\"Collection\""), "collection")
        XCTAssertEqual(CSVParser.cleanHeader("\"RA (J2000.0)\""), "ra(j20000)")
        XCTAssertEqual(CSVParser.cleanHeader("\"P.I. Name\""), "piname")
    }

    func testParseHeaderOnly() {
        let csv = "\"A\",\"B\",\"C\"\n"
        let (headers, rows) = CSVParser.parse(csv)
        XCTAssertEqual(headers.count, 3)
        XCTAssertEqual(rows.count, 0)
    }

    func testParseMismatchedColumns() {
        let csv = "\"A\",\"B\"\nx,y,z\n"
        let (_, rows) = CSVParser.parse(csv)
        XCTAssertEqual(rows.count, 0, "Row with wrong column count should be skipped")
    }
}

final class UnitConversionTests: XCTestCase {

    func testNormalizeWavelengthNm() throws {
        let metres = try normalizeToMetres("500nm")
        XCTAssertEqual(metres, 5e-7, accuracy: 1e-10)
    }

    func testNormalizeWavelengthUm() throws {
        let metres = try normalizeToMetres("1.5um")
        XCTAssertEqual(metres, 1.5e-6, accuracy: 1e-10)
    }

    func testNormalizeWavelengthAngstrom() throws {
        let metres = try normalizeToMetres("5000A")
        XCTAssertEqual(metres, 5e-7, accuracy: 1e-10)
    }

    func testNormalizeTimeSSeconds() throws {
        let seconds = try normalizeTimeValue("60", defaultUnit: "s")
        XCTAssertEqual(seconds, 60)
    }

    func testNormalizeTimeMinutes() throws {
        let seconds = try normalizeTimeValue("1m", defaultUnit: "s")
        XCTAssertEqual(seconds, 60)
    }

    func testNormalizeTimeHours() throws {
        let seconds = try normalizeTimeValue("2h", defaultUnit: "s")
        XCTAssertEqual(seconds, 7200)
    }

    func testPixelScaleArcsec() throws {
        let degrees = try normalizePixelScaleToDegrees("1")
        XCTAssertEqual(degrees, 1.0 / 3600.0, accuracy: 1e-10)
    }

    func testPixelScaleArcmin() throws {
        let degrees = try normalizePixelScaleToDegrees("1arcmin")
        XCTAssertEqual(degrees, 1.0 / 60.0, accuracy: 1e-10)
    }
}
