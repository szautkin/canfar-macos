// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Unit coverage for the canonical `SharedFormatters` namespace that feeds
/// timestamp and file-size display across search results, FITS metadata,
/// observation details, downloads, and VOSpace listings.
final class SharedFormattersTests: XCTestCase {

    // MARK: - ISO-8601 (fractional vs plain)

    func testISO8601FractionalParsesFractionalSeconds() {
        let date = SharedFormatters.iso8601Fractional.date(from: "2024-03-15T10:30:45.123Z")
        XCTAssertNotNil(date, "Fractional formatter must accept .123 fraction")
    }

    func testISO8601FractionalRejectsPlainTimestamp() {
        // Configured with `.withFractionalSeconds`, so a plain timestamp (no
        // fraction) is NOT accepted — this is exactly why SessionDisplay needs
        // a two-attempt fallback.
        let date = SharedFormatters.iso8601Fractional.date(from: "2024-03-15T10:30:45Z")
        XCTAssertNil(date, "Fractional formatter must reject a fraction-less timestamp")
    }

    func testISO8601ParsesPlainTimestamp() {
        let date = SharedFormatters.iso8601.date(from: "2024-03-15T10:30:45Z")
        XCTAssertNotNil(date, "Plain formatter must accept a fraction-less timestamp")
    }

    func testISO8601RejectsFractionalTimestamp() {
        // Without `.withFractionalSeconds`, the fraction is not tolerated.
        let date = SharedFormatters.iso8601.date(from: "2024-03-15T10:30:45.123Z")
        XCTAssertNil(date, "Plain formatter must reject a fractional timestamp")
    }

    func testISO8601FractionalRoundTrip() {
        let input = "2024-03-15T10:30:45.123Z"
        guard let date = SharedFormatters.iso8601Fractional.date(from: input) else {
            return XCTFail("Expected to parse \(input)")
        }
        XCTAssertEqual(SharedFormatters.iso8601Fractional.string(from: date), input)
    }

    func testISO8601RoundTrip() {
        let input = "2024-03-15T10:30:45Z"
        guard let date = SharedFormatters.iso8601.date(from: input) else {
            return XCTFail("Expected to parse \(input)")
        }
        XCTAssertEqual(SharedFormatters.iso8601.string(from: date), input)
    }

    // MARK: - UTC date formatters (POSIX locale)

    func testYYYYMMddUTCRoundTrip() {
        // Cross-check against an ISO instant: 2024-03-15T10:30:45Z is
        // 2024-03-15 in UTC (and stays 03-15 because the formatter is UTC).
        guard let instant = SharedFormatters.iso8601.date(from: "2024-03-15T10:30:45Z") else {
            return XCTFail("Setup parse failed")
        }
        XCTAssertEqual(SharedFormatters.yyyyMMddUTC.string(from: instant), "2024-03-15")

        // Round-trip the date-only string back to a Date and out again.
        guard let parsed = SharedFormatters.yyyyMMddUTC.date(from: "2024-03-15") else {
            return XCTFail("Expected to parse 2024-03-15")
        }
        XCTAssertEqual(SharedFormatters.yyyyMMddUTC.string(from: parsed), "2024-03-15")
    }

    func testYYYYMMddUTCUsesUTCTimeZone() {
        XCTAssertEqual(SharedFormatters.yyyyMMddUTC.timeZone, TimeZone(identifier: "UTC"))
        XCTAssertEqual(SharedFormatters.yyyyMMddUTC.locale, Locale(identifier: "en_US_POSIX"))
    }

    func testYYYYMMddHHmmssUTCRoundTrip() {
        guard let instant = SharedFormatters.iso8601.date(from: "2024-03-15T10:30:45Z") else {
            return XCTFail("Setup parse failed")
        }
        XCTAssertEqual(SharedFormatters.yyyyMMddHHmmssUTC.string(from: instant),
                       "2024-03-15 10:30:45")

        guard let parsed = SharedFormatters.yyyyMMddHHmmssUTC.date(from: "2024-03-15 10:30:45") else {
            return XCTFail("Expected to parse the full timestamp")
        }
        XCTAssertEqual(SharedFormatters.yyyyMMddHHmmssUTC.string(from: parsed),
                       "2024-03-15 10:30:45")
    }

    func testYYYYMMddHHmmssUTCUsesUTCTimeZoneAndPOSIXLocale() {
        XCTAssertEqual(SharedFormatters.yyyyMMddHHmmssUTC.timeZone, TimeZone(identifier: "UTC"))
        XCTAssertEqual(SharedFormatters.yyyyMMddHHmmssUTC.locale, Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - User-locale display formatters

    func testUserMediumDateProducesNonEmptyOutput() {
        // Locale-dependent rendering; assert it produces something rather than
        // a fixed English string so the test is locale-agnostic.
        let now = Date(timeIntervalSince1970: 1_710_499_845) // 2024-03-15T10:30:45Z
        XCTAssertFalse(SharedFormatters.userMediumDate.string(from: now).isEmpty)
    }

    func testUserMediumDateShortTimeProducesNonEmptyOutput() {
        let now = Date(timeIntervalSince1970: 1_710_499_845)
        XCTAssertFalse(SharedFormatters.userMediumDateShortTime.string(from: now).isEmpty)
    }

    func testMonthDayShortTimeMatchesCustomPattern() {
        // The search side panels render per-row timestamps with the literal
        // "MMM d, HH:mm" pattern. The POSIX locale keeps month abbreviations and
        // the comma/space layout stable regardless of the host locale. Use the
        // formatter's own time zone so the expected hour matches the rendering.
        let instant = Date(timeIntervalSince1970: 1_710_499_845) // 2024-03-15T10:30:45Z
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SharedFormatters.monthDayShortTime.timeZone
        let components = calendar.dateComponents([.hour, .minute], from: instant)
        let expected = String(format: "Mar 15, %02d:%02d", components.hour ?? -1, components.minute ?? -1)
        XCTAssertEqual(SharedFormatters.monthDayShortTime.string(from: instant), expected)
    }

    func testMonthDayShortTimeUsesPOSIXLocale() {
        XCTAssertEqual(SharedFormatters.monthDayShortTime.locale, Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Bytes

    func testBytesZero() {
        // Unit text is locale-dependent; assert the unit suffix like the other
        // byte tests rather than the exact localized "Zero KB" string.
        XCTAssertTrue(SharedFormatters.bytes(0).contains("KB"))
    }

    func testBytesMegabyte() {
        // 1 MB (file/decimal style) → "1 MB".
        let mb = SharedFormatters.bytes(1_000_000)
        XCTAssertTrue(mb.contains("MB"), "Expected MB unit, got \(mb)")
    }

    func testBytesGigabyte() {
        let gb = SharedFormatters.bytes(1_000_000_000)
        XCTAssertTrue(gb.contains("GB"), "Expected GB unit, got \(gb)")
    }

    func testBytesTerabyte() {
        let tb = SharedFormatters.bytes(1_000_000_000_000)
        XCTAssertTrue(tb.contains("TB"), "Expected TB unit, got \(tb)")
    }

    func testBytesUsesAllowedUnitsNotBytes() {
        // The formatter only allows KB/MB/GB/TB — a small count must not render
        // in raw "bytes"; it rounds up to the smallest allowed unit (KB).
        let small = SharedFormatters.bytes(2_048)
        XCTAssertTrue(small.contains("KB"), "Expected KB (allowedUnits excludes bytes), got \(small)")
    }

    func testBytesConvenienceMatchesUnderlyingFormatter() {
        XCTAssertEqual(SharedFormatters.bytes(1_500_000),
                       SharedFormatters.fileBytes.string(fromByteCount: 1_500_000))
    }
}
