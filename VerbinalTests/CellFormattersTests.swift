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
        // MJD 59000.0 = 2020-05-31 in UTC
        XCTAssertEqual(CellFormatters.format(key: "startdate", raw: "59000.0"), "2020-05-31")
    }

    func testMJDKnownDate() {
        // MJD 51544.0 = 2000-01-01 (J2000 epoch)
        XCTAssertEqual(CellFormatters.formatMJDDate("51544.0"), "2000-01-01")
    }

    func testMJDEmptyReturnsEmpty() {
        XCTAssertEqual(CellFormatters.format(key: "startdate", raw: ""), "")
    }

    func testMJDNonNumericPassthrough() {
        XCTAssertEqual(CellFormatters.format(key: "startdate", raw: "N/A"), "N/A")
    }

    func testEndDateAlsoFormats() {
        XCTAssertEqual(CellFormatters.format(key: "enddate", raw: "59000.0"), "2020-05-31")
    }

    // MARK: - Coordinate Formatting

    func testRAFormatting() {
        XCTAssertEqual(CellFormatters.format(key: "ra(j20000)", raw: "229.638423456"), "229.63842")
    }

    func testDecFormatting() {
        XCTAssertEqual(CellFormatters.format(key: "dec(j20000)", raw: "-12.3456789"), "-12.34568")
    }

    func testCoordinateNonNumericPassthrough() {
        XCTAssertEqual(CellFormatters.formatCoordinate("abc", decimalPlaces: 5), "abc")
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

    func testCalLevelUnknownPassthrough() {
        XCTAssertEqual(CellFormatters.format(key: "callev", raw: "5"), "5")
    }

    // MARK: - Integration Time

    func testIntegrationTime30Minutes() {
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "1800.0"), "30m")
    }

    func testIntegrationTime1Minute() {
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "60.0"), "1m")
    }

    func testIntegrationTime1Hour() {
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "3600.0"), "1h")
    }

    func testIntegrationTime45Seconds() {
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "45.0"), "45s")
    }

    func testIntegrationTimeFractionalMinutes() {
        XCTAssertEqual(CellFormatters.format(key: "inttime", raw: "90.0"), "1.5m")
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

    func testBooleanFalse() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "false"), "")
    }

    func testBooleanZero() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: "0"), "")
    }

    func testBooleanEmpty() {
        XCTAssertEqual(CellFormatters.format(key: "download", raw: ""), "")
    }

    func testMovingTargetBoolean() {
        XCTAssertEqual(CellFormatters.format(key: "movingtarget", raw: "true"), CellFormatters.checkmark)
    }

    // MARK: - Wavelength

    func testWavelengthSmallValue() {
        let result = CellFormatters.format(key: "minwavelength", raw: "0.0000005")
        XCTAssertTrue(result.contains("E"), "Small wavelength should use scientific notation, got: \(result)")
        XCTAssertTrue(result.contains("5.000"), "Should contain 5.000, got: \(result)")
    }

    func testWavelengthNormalValue() {
        let result = CellFormatters.formatWavelength("0.5")
        XCTAssertEqual(result, "0.5")
    }

    // MARK: - Default passthrough

    func testUnknownKeyPassthrough() {
        XCTAssertEqual(CellFormatters.format(key: "collection", raw: "JWST"), "JWST")
    }

    func testWhitespaceOnlyReturnsEmpty() {
        XCTAssertEqual(CellFormatters.format(key: "collection", raw: "   "), "")
    }
}
