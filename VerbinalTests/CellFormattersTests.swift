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

    // MARK: - Integration Time — default unit is "seconds" (CCDA parity)

    func testIntegrationTimeDefaultSecondsFormatting() {
        // CCDA default: 3-decimal seconds.
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "3600.0"), "3600.000 s")
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "1800.0"), "1800.000 s")
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "45.0"), "45.000 s")
    }

    func testIntegrationTimeDefaultPreservesSubSecondPrecision() {
        // 3-decimal precision means 0.05s renders faithfully, not rounded away.
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "0.05"), "0.050 s")
    }

    func testIntegrationTimeDefaultRendersZeroAndNegative() {
        // Unit-switchable formatter treats whatever the user sees as honest data
        // — CCDA parity shows "0.000 s", not an empty cell.
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "0"), "0.000 s")
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "-10"), "-10.000 s")
    }

    func testIntegrationTimeNonNumericPassthrough() {
        // Both the registry path and the legacy direct API passthrough on non-numeric.
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "unknown"), "unknown")
        XCTAssertEqual(CellFormatters.formatIntegrationTime("unknown"), "unknown")
    }

    func testLegacyDurationFormatterStillAutoPicks() {
        // The legacy DurationFormatter API (used by some callers and tests)
        // continues to auto-pick hours/minutes/seconds; the registry default
        // changed to CCDA's fixed seconds, but direct callers are unaffected.
        XCTAssertTrue(DurationFormatter().format("3600").contains("1"))
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

    // MARK: - Wavelength (metres base, user-switchable)

    func testWavelengthDefaultRendersInMetres() {
        // Default spectral unit is metres — matches CCDA.
        let out = CellFormatters.format(key: "minwavelength", raw: "5.0e-7")
        XCTAssertTrue(out.hasSuffix(" m"), "Expected metres unit, got: \(out)")
    }

    func testWavelengthOpticalAsNanometres() {
        // 5e-7 m = 500 nm when the caller requests nm explicitly.
        let out = CellFormatterRegistry.format(id: "minwavelength", raw: "5.0e-7", unitID: "nm")
        XCTAssertEqual(out, "500.0 nm")
    }

    func testWavelengthInfraredAsMicrometres() {
        let out = CellFormatterRegistry.format(id: "minwavelength", raw: "2.2e-6", unitID: "um")
        XCTAssertEqual(out, "2.20 \u{03BC}m")
    }

    func testWavelengthAsFrequencyGHz() {
        // 1 mm wavelength = 299.79 GHz.
        let out = CellFormatterRegistry.format(id: "minwavelength", raw: "1e-3", unitID: "ghz")
        XCTAssertTrue(out.contains("GHz"), "Expected GHz, got: \(out)")
        XCTAssertTrue(out.contains("299"), "Expected ~299 GHz, got: \(out)")
    }

    func testWavelengthAsEnergyKeV() {
        // X-ray wavelength 1 Å = 1e-10 m → ~12.4 keV.
        let out = CellFormatterRegistry.format(id: "minwavelength", raw: "1e-10", unitID: "kev")
        XCTAssertTrue(out.contains("keV"), "Expected keV, got: \(out)")
        XCTAssertTrue(out.contains("12"), "Expected ~12.4 keV, got: \(out)")
    }

    func testWavelengthNaNPassesThrough() {
        XCTAssertEqual(CellFormatters.format(key: "minwavelength", raw: "NaN"), "NaN")
    }

    func testWavelengthZeroRejected() {
        // Cross-dimension converters would divide by zero; the formatter
        // returns the raw input so the user sees the server's value.
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "minwavelength", raw: "0", unitID: "nm"),
            "0"
        )
    }

    // MARK: - Angle (pixel scale default is Arcseconds — CCDA parity)

    func testPixelScaleDefaultRendersArcsec() {
        // 0.2″ = 0.2/3600 degrees → 0.200″
        let raw = String(0.2 / 3600.0)
        let out = CellFormatters.format(key: "pixelscale", raw: raw)
        XCTAssertTrue(out.hasPrefix("0.200"), "Expected 0.200 arcsec prefix, got: \(out)")
        XCTAssertTrue(out.hasSuffix("\u{2033}"), "Expected arcsecond suffix, got: \(out)")
    }

    func testFieldOfViewDefaultIsSquareDegrees() {
        // CCDA default for FoV is sq.deg — not arcmin even for small values.
        let raw = String(10.0 / 60.0)  // 10 arcmin = 0.1667 sq.deg... wait, this is a LINEAR angle not AREA
        let out = CellFormatters.format(key: "fieldofview", raw: raw)
        XCTAssertTrue(out.hasSuffix("sq deg"), "Default FoV unit is sq.deg, got: \(out)")
    }

    func testFieldOfViewLargeStillInSquareDegrees() {
        let out = CellFormatters.format(key: "fieldofview", raw: "2.5")
        XCTAssertTrue(out.hasPrefix("2.500"))
        XCTAssertTrue(out.hasSuffix("sq deg"))
    }

    func testLegacyAngleFormatterStillAvailable() {
        // The original auto-formatter remains reachable for callers that
        // want the "arcsec/px" compound suffix.
        let raw = String(0.2 / 3600.0)
        let out = AngleFormatter(mode: .arcsecPerPixel).format(raw)
        XCTAssertTrue(out.contains("/px"))
    }

    // MARK: - Default passthrough

    func testUnknownKeyPassthrough() {
        XCTAssertEqual(CellFormatters.format(key: "collection", raw: "JWST"), "JWST")
    }

    func testWhitespaceOnlyReturnsEmpty() {
        XCTAssertEqual(CellFormatters.format(key: "collection", raw: "   "), "")
    }
}
