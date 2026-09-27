// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

final class SexagesimalTests: XCTestCase {

    // MARK: - Carry (the 60.00 bug)

    func testSecondsThatRoundUpCarryIntoTheMinute() {
        // 23h59m59.996s — %05.2f on the float remainder printed 59m60.00s.
        let degrees = (23 + 59.0 / 60 + 59.996 / 3600) * 15
        XCTAssertEqual(Sexagesimal.formatHMS(degrees: degrees), "00h00m00.00s")
        let noon = (12 + 34.0 / 60 + 59.996 / 3600) * 15
        XCTAssertEqual(Sexagesimal.formatHMS(degrees: noon), "12h35m00.00s")
    }

    func testArcsecondsThatRoundUpCarryIntoTheDegree() {
        let dec = 41 + 59.0 / 60 + 59.97 / 3600
        XCTAssertEqual(Sexagesimal.formatDMS(degrees: dec), "+42\u{00B0}00'00.0\"")
        XCTAssertEqual(Sexagesimal.formatDMS(degrees: -dec, style: .colons), "-42:00:00.0")
    }

    // MARK: - Ranges and signs

    func testRightAscensionWrapsIntoOneDay() {
        XCTAssertEqual(Sexagesimal.formatHMS(degrees: 360, style: .colons), "00:00:00.00")
        XCTAssertEqual(Sexagesimal.formatHMS(degrees: -15, style: .colons), "23:00:00.00")
        XCTAssertEqual(Sexagesimal.formatHMS(degrees: 180), "12h00m00.00s")
    }

    func testDeclinationOutsideNinetyIsNotFormatted() {
        XCTAssertNil(Sexagesimal.formatDMS(degrees: 95))
        XCTAssertNil(Sexagesimal.formatDMS(degrees: .nan))
        XCTAssertNil(Sexagesimal.formatHMS(degrees: .infinity))
        XCTAssertEqual(Sexagesimal.formatDMS(degrees: -90, style: .colons), "-90:00:00.0")
    }

    func testATinyNegativeDeclinationRoundsToPlusZero() {
        XCTAssertEqual(Sexagesimal.formatDMS(degrees: -0.000001), "+00\u{00B0}00'00.0\"")
    }

    func testSecondDigitsControlPrecision() {
        XCTAssertEqual(Sexagesimal.formatHMS(degrees: 10.684708, secondDigits: 3, style: .colons), "00:42:44.330")
        XCTAssertEqual(Sexagesimal.formatDMS(degrees: 41.26875, secondDigits: 0, style: .colons), "+41:16:08")
    }

    // MARK: - Parsing

    func testStrictParsersAcceptEverySeparatorStyle() throws {
        let ra = (0 + 42.0 / 60 + 44.33 / 3600) * 15
        for text in ["00:42:44.33", "00 42 44.33", "00h42m44.33s", "0h42m44,33s"] {
            XCTAssertEqual(try XCTUnwrap(Sexagesimal.parseHMS(text), text), ra, accuracy: 1e-9, text)
        }
        let dec = 41 + 16.0 / 60 + 9.0 / 3600
        for text in ["+41:16:09", "41 16 09", "+41°16'09\"", "41°16′09″"] {
            XCTAssertEqual(try XCTUnwrap(Sexagesimal.parseDMS(text), text), dec, accuracy: 1e-9, text)
        }
        XCTAssertEqual(try XCTUnwrap(Sexagesimal.parseDMS("\u{2212}00 30 00")), -0.5, accuracy: 1e-12)
    }

    func testStrictParsersRejectOutOfRangeAndSingleFields() {
        XCTAssertNil(Sexagesimal.parseHMS("24:00:00"))
        XCTAssertNil(Sexagesimal.parseHMS("12:60:00"))
        XCTAssertNil(Sexagesimal.parseHMS("10.5"))
        XCTAssertNil(Sexagesimal.parseDMS("91:00:00"))
        XCTAssertNil(Sexagesimal.parseDMS("90:00:01"))
        XCTAssertNil(Sexagesimal.parseDMS("M31"))
    }

    /// Decimal degrees with a point or a comma — a French Mac types 10,68.
    func testLenientParsersTakeDecimalDegreesOrSexagesimal() throws {
        XCTAssertEqual(Sexagesimal.rightAscension("10.684708"), 10.684708)
        XCTAssertEqual(Sexagesimal.rightAscension("10,684708"), 10.684708)
        XCTAssertEqual(try XCTUnwrap(Sexagesimal.rightAscension("00:42:44.33")),
                       (42.0 / 60 + 44.33 / 3600) * 15, accuracy: 1e-9)
        XCTAssertEqual(Sexagesimal.declination("-41,5"), -41.5)
        XCTAssertNil(Sexagesimal.rightAscension("360"))
        XCTAssertNil(Sexagesimal.declination("-91"))
        XCTAssertNil(Sexagesimal.declination(""))
    }

    func testFormatThenParseRoundTrips() throws {
        for ra in [0.0, 10.684708, 83.8221, 201.365, 359.99] {
            let text = try XCTUnwrap(Sexagesimal.formatHMS(degrees: ra, secondDigits: 3))
            XCTAssertEqual(try XCTUnwrap(Sexagesimal.parseHMS(text)), ra, accuracy: 0.0005 * 15 / 3600 + 1e-9, text)
        }
        for dec in [-89.5, -5.391, 0, 41.26875, 89.99] {
            let text = try XCTUnwrap(Sexagesimal.formatDMS(degrees: dec, secondDigits: 2))
            XCTAssertEqual(try XCTUnwrap(Sexagesimal.parseDMS(text)), dec, accuracy: 0.005 / 3600 + 1e-9, text)
        }
    }

    /// Two tokens the Search box reads back to the same place.
    func testSearchPairReadsBack() throws {
        let pair = try XCTUnwrap(Sexagesimal.searchPair(ra: 10.684708, dec: 41.269167))
        XCTAssertEqual(pair, "00:42:44.33 +41:16:09.0")
        let tokens = pair.split(separator: " ").map(String.init)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(try XCTUnwrap(Sexagesimal.rightAscension(tokens[0])), 10.684708, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(Sexagesimal.declination(tokens[1])), 41.269167, accuracy: 1e-4)
        XCTAssertNil(Sexagesimal.searchPair(ra: 10, dec: 91))
    }
}
