// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

// MARK: - DateParser Tests

final class DateParserTests: XCTestCase {

    func testParseISODate() throws {
        let parsed = try parseSingleDate("2020-03-15")
        XCTAssertEqual(parsed.format, .iso)
        XCTAssertEqual(parsed.granularity, .day)
    }

    func testParseISODateTime() throws {
        let parsed = try parseSingleDate("2020-03-15T10:30:00")
        XCTAssertEqual(parsed.format, .iso)
        XCTAssertEqual(parsed.granularity, .second)
    }

    func testParseYearOnly() throws {
        let parsed = try parseSingleDate("2018")
        XCTAssertEqual(parsed.format, .iso)
        XCTAssertEqual(parsed.granularity, .year)
    }

    func testParseMJD() throws {
        let parsed = try parseSingleDate("59000.0")
        XCTAssertEqual(parsed.format, .mjd)
    }

    func testParseJD() throws {
        // JD threshold is 2400000.5 — values above are JD
        let parsed = try parseSingleDate("2459000.5")
        XCTAssertEqual(parsed.format, .jd)
    }

    func testExpandSingleDateYear() throws {
        let range = try expandSingleDateToRange("2018")
        XCTAssertTrue(range.upper > range.lower, "Upper should be > lower")
        // 2018 spans ~365 days in MJD
        XCTAssertEqual(range.upper - range.lower, 365, accuracy: 1.0)
    }

    func testExpandSingleDateDay() throws {
        let range = try expandSingleDateToRange("2020-03-15")
        XCTAssertEqual(range.upper - range.lower, 1.0, accuracy: 0.01)
    }

    func testDateToMJDKnownValue() throws {
        // J2000 epoch: 2000-01-01 = MJD 51544
        let mjd = try dateToMJDValue("2000-01-01")
        XCTAssertEqual(mjd, 51544.0, accuracy: 1.0)
    }

    func testDatePresetPast24Hours() {
        let result = expandDatePreset(.past24Hours)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains(".."), "Should be a range")
    }

    func testInvalidDateThrows() {
        XCTAssertThrowsError(try parseSingleDate("not-a-date"))
    }
}

// MARK: - TemporalBuilder Tests

final class TemporalBuilderTests: XCTestCase {

    func testDateRangeClause() {
        let clauses = TemporalBuilder.buildWhere(date: "2020..2021", preset: .none, exposure: "", timeSpan: "")
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("INTERSECTS"), "Should use INTERSECTS for date range")
        XCTAssertTrue(clauses[0].contains("INTERVAL"), "Should use INTERVAL")
    }

    func testDatePresetClause() {
        let clauses = TemporalBuilder.buildWhere(date: "", preset: .past24Hours, exposure: "", timeSpan: "")
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("INTERSECTS"))
    }

    func testExposureRange() {
        let clauses = TemporalBuilder.buildWhere(date: "", preset: .none, exposure: "100..500", timeSpan: "")
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("time_exposure"))
        XCTAssertTrue(clauses[0].contains(">=") && clauses[0].contains("<="))
    }

    func testExposureGreaterThan() {
        let clauses = TemporalBuilder.buildWhere(date: "", preset: .none, exposure: "> 1h", timeSpan: "")
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("3600"), "1h = 3600 seconds")
    }

    func testTimeSpanDays() {
        let clauses = TemporalBuilder.buildWhere(date: "", preset: .none, exposure: "", timeSpan: "1d")
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("time_bounds_width"))
    }

    func testEmptyInputsNoClause() {
        let clauses = TemporalBuilder.buildWhere(date: "", preset: .none, exposure: "", timeSpan: "")
        XCTAssertEqual(clauses.count, 0)
    }
}

// MARK: - SpectralBuilder Tests

final class SpectralBuilderTests: XCTestCase {

    func testCoverageRange() {
        let clauses = SpectralBuilder.buildWhere(coverage: "400..700nm", sampling: "", resolvingPower: "", bandpassWidth: "", restFrameEnergy: "")
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("energy_bounds"), "Should reference energy bounds columns")
    }

    func testCoveragePoint() {
        let clauses = SpectralBuilder.buildWhere(coverage: "500nm", sampling: "", resolvingPower: "", bandpassWidth: "", restFrameEnergy: "")
        XCTAssertEqual(clauses.count, 1)
        // 500nm = 5e-7 metres — exact format may vary (5e-07 or 5.000...e-07)
        XCTAssertTrue(clauses[0].contains("e-07"), "Should contain e-07 for 500nm, got: \(clauses[0])")
    }

    func testResolvingPowerRange() {
        let clauses = SpectralBuilder.buildWhere(coverage: "", sampling: "", resolvingPower: "1000..5000", bandpassWidth: "", restFrameEnergy: "")
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("resolvingPower"))
        XCTAssertTrue(clauses[0].contains("1000") && clauses[0].contains("5000"))
    }

    func testBandpassWidthLessThan() {
        let clauses = SpectralBuilder.buildWhere(coverage: "", sampling: "", resolvingPower: "", bandpassWidth: "< 100nm", restFrameEnergy: "")
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("bounds_width"))
    }

    func testEmptyInputsNoClause() {
        let clauses = SpectralBuilder.buildWhere(coverage: "", sampling: "", resolvingPower: "", bandpassWidth: "", restFrameEnergy: "")
        XCTAssertEqual(clauses.count, 0)
    }
}

// MARK: - MiscBuilder Tests

final class MiscBuilderTests: XCTestCase {

    func testIntentScience() {
        let clause = MiscBuilder.buildIntentClause(.science)
        XCTAssertEqual(clause, "Observation.intent = 'science'")
    }

    func testIntentCalibration() {
        let clause = MiscBuilder.buildIntentClause(.calibration)
        XCTAssertEqual(clause, "Observation.intent = 'calibration'")
    }

    func testIntentAnyReturnsNil() {
        XCTAssertNil(MiscBuilder.buildIntentClause(.any))
    }

    func testPublicOnlyTrue() {
        let clause = MiscBuilder.buildPublicOnlyClause(true)
        XCTAssertNotNil(clause)
        XCTAssertTrue(clause!.contains("dataRelease"))
    }

    func testPublicOnlyFalseReturnsNil() {
        XCTAssertNil(MiscBuilder.buildPublicOnlyClause(false))
    }

    func testDataReleaseRange() {
        let clause = MiscBuilder.buildDataReleaseClause("2020..2021")
        XCTAssertNotNil(clause)
        XCTAssertTrue(clause!.contains("dataRelease"))
        XCTAssertTrue(clause!.contains(">=") && clause!.contains("<="))
    }

    func testDataReleaseEmpty() {
        XCTAssertNil(MiscBuilder.buildDataReleaseClause(""))
    }
}

// MARK: - SpatialBuilder Additional Tests

final class SpatialBuilderAdditionalTests: XCTestCase {

    func testCoordRangeMode() {
        let params = SpatialBuilder.Params(target: "10..11 40..41", resolver: .all, resolverCoords: nil, pixelScale: "")
        let clauses = SpatialBuilder.buildWhere(params)
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("RANGE_S2D"))
    }

    func testTargetNameNoResolver() {
        let params = SpatialBuilder.Params(target: "NGC 1234", resolver: .none, resolverCoords: nil, pixelScale: "")
        let clauses = SpatialBuilder.buildWhere(params)
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("LIKE"))
        XCTAssertTrue(clauses[0].lowercased().contains("ngc 1234"))
    }

    func testPixelScaleRange() {
        let params = SpatialBuilder.Params(target: "", resolver: .none, resolverCoords: nil, pixelScale: "0.5..2")
        let clauses = SpatialBuilder.buildWhere(params)
        XCTAssertEqual(clauses.count, 1)
        XCTAssertTrue(clauses[0].contains("position_sampleSize"))
    }

    func testEmptyTargetNoClause() {
        let params = SpatialBuilder.Params(target: "", resolver: .none, resolverCoords: nil, pixelScale: "")
        let clauses = SpatialBuilder.buildWhere(params)
        XCTAssertEqual(clauses.count, 0)
    }
}
