// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class CellFormattersTests: XCTestCase {

    // MARK: - MJD Date Formatting

    func testMJDToDateFormatting() {
        // MJD 59000.0 = 2020-05-31 UTC; default style includes time (matches CADC CCDA).
        XCTAssertEqual(CellFormatters.format(key: "startdate", raw: "59000.0"), "2020-05-31 00:00:00")
    }

    func testMJDKnownDate() {
        // Legacy wrapper — default MJDFormatter style is dateAndTime now.
        XCTAssertEqual(CellFormatters.formatMJDDate("51544.0"), "2000-01-01 00:00:00")
    }

    func testMJDEmptyReturnsEmpty() {
        XCTAssertEqual(CellFormatters.format(key: "startdate", raw: ""), "")
    }

    func testMJDNonNumericPassthrough() {
        XCTAssertEqual(CellFormatters.format(key: "startdate", raw: "N/A"), "N/A")
    }

    func testEndDateAlsoFormats() {
        XCTAssertEqual(CellFormatters.format(key: "enddate", raw: "59000.0"), "2020-05-31 00:00:00")
    }

    func testMJDWithFractionalIncludesTime() {
        // MJD 59000.5 = 2020-05-31 12:00:00 UTC
        let out = CellFormatters.format(key: "startdate", raw: "59000.5")
        XCTAssertEqual(out, "2020-05-31 12:00:00")
    }

    func testMJDInfRejected() {
        // Non-finite values pass through raw, not rendered as "inf-ish date"
        XCTAssertEqual(CellFormatters.format(key: "startdate", raw: "Infinity"), "Infinity")
        XCTAssertEqual(CellFormatters.format(key: "startdate", raw: "NaN"), "NaN")
    }

    // MARK: - ISO Timestamp

    func testProveLastExecutedUsesTimestampFormatter() {
        // Was incorrectly routed through MJD parser before the refactor.
        let out = CellFormatters.format(key: "provelastexecuted", raw: "2024-03-15T10:30:45.123Z")
        XCTAssertEqual(out, "2024-03-15 10:30:45")
    }

    func testDataReleaseISO() {
        XCTAssertEqual(
            CellFormatters.format(key: "datarelease", raw: "2025-06-30T00:00:00Z"),
            "2025-06-30 00:00:00"
        )
    }

    func testTimestampShortInputIsSafe() {
        XCTAssertEqual(CellFormatters.formatTimestamp("short"), "short")
    }

    // MARK: - Coordinate Formatting

    // MARK: - Coordinate default unit (HMS for RA, DMS for Dec)

    func testRADefaultIsHMS() {
        // 229.638423456° / 15 = 15h 18m 33.22s
        XCTAssertEqual(CellFormatters.format(key: "ra(j20000)", raw: "229.638423456"), "15:18:33.22")
    }

    func testDecDefaultIsDMS() {
        // 12.3456789° → +12° 20′ 44.4″
        XCTAssertEqual(CellFormatters.format(key: "dec(j20000)", raw: "12.3456789"), "+12:20:44.4")
    }

    func testDecNegativeDMS() {
        XCTAssertEqual(CellFormatters.format(key: "dec(j20000)", raw: "-12.3456789"), "-12:20:44.4")
    }

    // MARK: - Coordinate explicit-unit (degrees)

    func testRADegreesUnit() {
        // When the caller asks for degrees, use 6 decimals.
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "ra(j20000)", raw: "229.638423456", unitID: "degrees"),
            "229.638423"
        )
    }

    func testDecDegreesUnitShowsSign() {
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "dec(j20000)", raw: "12.3456789", unitID: "degrees"),
            "+12.345679"
        )
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "dec(j20000)", raw: "-12.3456789", unitID: "degrees"),
            "-12.345679"
        )
    }

    // MARK: - HMS/DMS edge cases

    func testHMSWraps360Degrees() {
        // 360° = 24h → wraps back to 00:00:00.00
        XCTAssertEqual(HMSFormatter().format("360"), "00:00:00.00")
    }

    func testHMSHandlesNegativeRA() {
        // -15° should wrap into positive hours: -1h → 23h
        XCTAssertEqual(HMSFormatter().format("-15"), "23:00:00.00")
    }

    func testDMSRejectsOutOfRangeDec() {
        // Dec outside [-90, 90] is implausible — passthrough, don't fabricate.
        XCTAssertEqual(DMSFormatter().format("95"), "95")
        XCTAssertEqual(DMSFormatter().format("-100"), "-100")
    }

    func testDMSBoundary() {
        XCTAssertEqual(DMSFormatter().format("90"), "+90:00:00.0")
        XCTAssertEqual(DMSFormatter().format("-90"), "-90:00:00.0")
    }

    func testHMSAndDMSPassNonNumeric() {
        XCTAssertEqual(HMSFormatter().format("N/A"), "N/A")
        XCTAssertEqual(DMSFormatter().format("N/A"), "N/A")
    }

    func testCoordinateNonNumericPassthrough() {
        XCTAssertEqual(CellFormatters.formatCoordinate("abc", decimalPlaces: 5), "abc")
    }

    func testCoordinateNaNPassesThrough() {
        XCTAssertEqual(CellFormatters.format(key: "ra(j20000)", raw: "NaN"), "NaN")
    }

    // MARK: - Calibration Level

    func testCalLevelRaw() {
        XCTAssertEqual(CellFormatters.format(key: "callev", raw: "0"), "Raw")
    }

    func testCalLevelCal() {
        XCTAssertEqual(CellFormatters.format(key: "callev", raw: "1"), "Cal")
    }

    func testCalLevelProduct() {
        XCTAssertEqual(CellFormatters.format(key: "callev", raw: "2"), "Product")
    }

    func testCalLevelComposite() {
        XCTAssertEqual(CellFormatters.format(key: "callev", raw: "3"), "Composite")
    }

    func testCalLevelAnalysis() {
        // CAOM2 level 4 — added in refactor
        XCTAssertEqual(CellFormatters.format(key: "callev", raw: "4"), "Analysis")
    }

    func testCalLevelUnknownPassthrough() {
        XCTAssertEqual(CellFormatters.format(key: "callev", raw: "7"), "7")
    }

    // MARK: - Integration Time

    func testIntegrationTime1Hour() {
        // Duration.FormatStyle output is locale-dependent; assert shape, not exact glyph
        let out = CellFormatters.format(key: "inttime", raw: "3600.0")
        XCTAssertTrue(out.contains("1"), "Expected '1' hour, got: \(out)")
        XCTAssertFalse(out.isEmpty)
    }

    func testIntegrationTime30Minutes() {
        let out = CellFormatters.format(key: "inttime", raw: "1800.0")
        XCTAssertTrue(out.contains("30"), "Expected 30 minutes, got: \(out)")
    }

    func testIntegrationTime45Seconds() {
        let out = CellFormatters.format(key: "inttime", raw: "45.0")
        XCTAssertTrue(out.contains("45"), "Expected 45 seconds, got: \(out)")
    }

    func testIntegrationTimeSubSecondDoesNotRoundToZero() {
        // Previously 0.05s → 0.1s (misleading); now shows two decimals.
        let out = CellFormatters.format(key: "inttime", raw: "0.05")
        XCTAssertTrue(out.contains("0.05"), "Sub-second should keep precision, got: \(out)")
    }

    func testIntegrationTimeZeroAndNegativeRejected() {
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "0"), "")
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "-10"), "")
    }

    func testIntegrationTimeNonNumericPassthrough() {
        XCTAssertEqual(CellFormatters.formatIntegrationTime("unknown"), "unknown")
    }

    // MARK: - Boolean

    func testBooleanTrue() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "true"), CellFormatters.checkmark)
    }

    func testBooleanOne() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "1"), CellFormatters.checkmark)
    }

    func testBooleanFalseRendersAsEmDash() {
        // Previously empty — now explicit em-dash for accessibility.
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "false"), "\u{2014}")
    }

    func testBooleanZeroRendersAsEmDash() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "0"), "\u{2014}")
    }

    func testBooleanEmpty() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: ""), "")
    }

    func testBooleanYesNoAccepted() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "yes"), CellFormatters.checkmark)
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "no"), "\u{2014}")
    }

    func testBooleanTFAccepted() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "T"), CellFormatters.checkmark)
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "F"), "\u{2014}")
    }

    func testMovingTargetBoolean() {
        XCTAssertEqual(CellFormatters.format(key: "movingtarget", raw: "true"), CellFormatters.checkmark)
    }

    // MARK: - Wavelength (metres → human units)

    func testWavelengthOptical() {
        // 5e-7 m = 500 nm
        let out = CellFormatters.format(key: "minwavelength", raw: "5.0e-7")
        XCTAssertTrue(out.contains("nm") && out.contains("500"), "Expected '500 nm'-ish, got: \(out)")
    }

    func testWavelengthInfrared() {
        // 2.2e-6 m = 2.2 μm
        let out = CellFormatters.format(key: "minwavelength", raw: "2.2e-6")
        XCTAssertTrue(out.contains("\u{03BC}m"), "Expected micrometre symbol, got: \(out)")
    }

    func testWavelengthNaNPassesThrough() {
        XCTAssertEqual(CellFormatters.format(key: "minwavelength", raw: "NaN"), "NaN")
    }

    // MARK: - Angle

    func testPixelScaleRendersArcsec() {
        // 0.2 arcsec = 0.2 / 3600 degrees
        let raw = String(0.2 / 3600.0)
        let out = CellFormatters.format(key: "pixelscale", raw: raw)
        XCTAssertTrue(out.contains("/px"), "Expected '/px' suffix, got: \(out)")
        XCTAssertTrue(out.contains("0.2"), "Expected 0.2, got: \(out)")
    }

    func testFieldOfViewSmallUsesArcmin() {
        // 10 arcmin = 10 / 60 degrees
        let raw = String(10.0 / 60.0)
        let out = CellFormatters.format(key: "fieldofview", raw: raw)
        XCTAssertTrue(out.contains("\u{2032}"), "Expected arcmin symbol, got: \(out)")
    }

    func testFieldOfViewLargeUsesDegrees() {
        let out = CellFormatters.format(key: "fieldofview", raw: "2.5")
        XCTAssertTrue(out.contains("\u{00B0}"), "Expected degree symbol, got: \(out)")
    }

    // MARK: - Default passthrough

    func testUnknownKeyPassthrough() {
        XCTAssertEqual(CellFormatters.format(key: "collection", raw: "JWST"), "JWST")
    }

    func testWhitespaceOnlyReturnsEmpty() {
        XCTAssertEqual(CellFormatters.format(key: "collection", raw: "   "), "")
    }
}
