// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Covers the CCDA-parity unit-switch columns added alongside the spectral
/// converter: integration time, pixel scale, field of view, start/end date,
/// and image quality. For each column we test:
///  • the default unit matches CCDA's documented default
///  • every registered unit id actually renders something plausible
///  • numeric magic (conversion factors, rounding) matches the CCDA reference
final class UnitSwitchingParityTests: XCTestCase {

    // MARK: - Integration time (seconds base)

    func testInttimeDefaultIsSeconds() {
        XCTAssertEqual(CellFormatterRegistry.defaultUnitID(for: "inttime"), "seconds")
    }

    func testInttimeSecondsUnit() {
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "inttime", raw: "3600", unitID: "seconds"),
            "3600.000 s"
        )
    }

    func testInttimeMinutesUnit() {
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "inttime", raw: "3600", unitID: "minutes"),
            "60.000 m"
        )
    }

    func testInttimeHoursUnit() {
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "inttime", raw: "3600", unitID: "hours"),
            "1.000 h"
        )
    }

    func testInttimeDaysUnit() {
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "inttime", raw: "86400", unitID: "days"),
            "1.000 d"
        )
    }

    func testInttimeAllFourChoicesRegistered() {
        let ids = (CellFormatterRegistry.availableUnits(for: "inttime") ?? []).map(\.unitID)
        XCTAssertEqual(Set(ids), ["seconds", "minutes", "hours", "days"])
    }

    // MARK: - Pixel scale (degrees base)

    func testPixelScaleDefaultIsArcseconds() {
        XCTAssertEqual(CellFormatterRegistry.defaultUnitID(for: "pixelscale"), "arcseconds")
    }

    func testPixelScaleAllFourUnitsRegistered() {
        let ids = (CellFormatterRegistry.availableUnits(for: "pixelscale") ?? []).map(\.unitID)
        XCTAssertEqual(Set(ids), ["milliarcseconds", "arcseconds", "arcminutes", "degrees"])
    }

    func testPixelScaleArcsecondsConversion() {
        // 0.2 arcsec = 0.2 / 3600 degrees
        let raw = String(0.2 / 3600.0)
        let out = CellFormatterRegistry.format(id: "pixelscale", raw: raw, unitID: "arcseconds")
        XCTAssertTrue(out.hasPrefix("0.200"), "Expected 0.200 arcsec, got \(out)")
        XCTAssertTrue(out.hasSuffix("\u{2033}"), "Expected arcsecond symbol, got \(out)")
    }

    func testPixelScaleMilliarcsecondsConversion() {
        // Same 0.2″ input → 200 mas.
        let raw = String(0.2 / 3600.0)
        let out = CellFormatterRegistry.format(id: "pixelscale", raw: raw, unitID: "milliarcseconds")
        XCTAssertTrue(out.hasPrefix("200.000"), "Expected 200.000 mas, got \(out)")
        XCTAssertTrue(out.hasSuffix("mas"))
    }

    func testPixelScaleDegreesUnit() {
        let raw = String(0.2 / 3600.0)  // 0.2″ in degrees
        let out = CellFormatterRegistry.format(id: "pixelscale", raw: raw, unitID: "degrees")
        // 0.000055556° — magnitude < 0.001 so 6 decimals
        XCTAssertTrue(out.contains("0.000056") || out.contains("0.000055"),
                      "Expected 6-decimal degree, got \(out)")
        XCTAssertTrue(out.hasSuffix("\u{00B0}"))
    }

    // MARK: - Image quality (same angular base as pixelscale, no degrees)

    func testImageQualityDefaultIsArcseconds() {
        XCTAssertEqual(CellFormatterRegistry.defaultUnitID(for: "positionresolution"), "arcseconds")
    }

    func testImageQualityOmitsDegrees() {
        let ids = (CellFormatterRegistry.availableUnits(for: "positionresolution") ?? []).map(\.unitID)
        // IQ never uses degrees — CCDA omits it from this column's menu.
        XCTAssertEqual(Set(ids), ["milliarcseconds", "arcseconds", "arcminutes"])
    }

    // MARK: - Field of view (square-degrees base)

    func testFieldOfViewDefaultIsSquareDegrees() {
        XCTAssertEqual(CellFormatterRegistry.defaultUnitID(for: "fieldofview"), "sq_deg")
    }

    func testFieldOfViewSquareArcminConversion() {
        // 1 sq.deg = 3600 sq.arcmin
        let out = CellFormatterRegistry.format(id: "fieldofview", raw: "1", unitID: "sq_arcmin")
        XCTAssertTrue(out.hasPrefix("3600.000"), "Expected 3600.000 sq arcmin, got \(out)")
    }

    func testFieldOfViewSquareArcsecConversion() {
        // 1 sq.deg = 12,960,000 sq.arcsec
        let out = CellFormatterRegistry.format(id: "fieldofview", raw: "1", unitID: "sq_arcsec")
        XCTAssertTrue(out.hasPrefix("12960000"), "Expected 12960000-ish, got \(out)")
    }

    func testFieldOfViewSubThousandthPrecision() {
        // A tiny FoV should render with 6 decimals (CCDA adaptive precision).
        let out = CellFormatterRegistry.format(id: "fieldofview", raw: "0.0001", unitID: "sq_deg")
        XCTAssertTrue(out.contains("0.000100"), "Expected 6-decimal rendering, got \(out)")
    }

    // MARK: - Dates (Calendar default, MJD alternative)

    func testStartDateDefaultIsCalendar() {
        XCTAssertEqual(CellFormatterRegistry.defaultUnitID(for: "startdate"), "calendar")
        XCTAssertEqual(CellFormatterRegistry.defaultUnitID(for: "enddate"), "calendar")
    }

    func testStartDateMJDUnit() {
        // MJD unit passes the value through — the MJD numeric is native.
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "startdate", raw: "59000.5", unitID: "mjd"),
            "59000.5"
        )
    }

    func testStartDateCalendarUnitPreservesExistingBehavior() {
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "startdate", raw: "59000.5", unitID: "calendar"),
            "2020-05-31 12:00:00"
        )
    }

    func testEndDateMJDRejectsNaN() {
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "enddate", raw: "NaN", unitID: "mjd"),
            "NaN"
        )
    }

    // MARK: - Overall parity gate

    func testEveryCCDAUnitSwitchColumnIsRegistered() {
        // A failing assertion here means we've lost an entry the CCDA reference
        // exposes — regression guard for 100% parity.
        let expected: Set<String> = [
            "ra(j20000)", "dec(j20000)",                // coordinates
            "minwavelength", "maxwavelength", "restframeenergy",  // spectral
            "inttime",                                  // duration
            "pixelscale", "positionresolution",         // angle
            "fieldofview",                              // area
            "startdate", "enddate",                     // dates
        ]
        let registered = Set(CellFormatterRegistry.sets.keys)
        XCTAssertTrue(expected.isSubset(of: registered),
                      "Missing parity columns: \(expected.subtracting(registered))")
    }
}
