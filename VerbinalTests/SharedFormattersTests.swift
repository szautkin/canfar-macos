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

    func testUserMediumDateShortTimeProducesNonEmptyOutput() {
        // Locale-dependent rendering; assert it produces something rather than
        // a fixed English string so the test is locale-agnostic.
        let now = Date(timeIntervalSince1970: 1_710_499_845) // 2024-03-15T10:30:45Z
        XCTAssertFalse(SharedFormatters.userMediumDateShortTime.string(from: now).isEmpty)
        XCTAssertFalse(SharedFormatters.userMediumDateTime.string(from: now).isEmpty)
    }

    func testFileNameStampIsSortableAndPOSIX() throws {
        let f = SharedFormatters.fileNameStamp
        XCTAssertEqual(f.locale.identifier, "en_US_POSIX")
        // Local wall-clock components, matching the formatter's local zone.
        let date = try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            year: 2026, month: 9, day: 3, hour: 7, minute: 5, second: 9).date)
        XCTAssertEqual(f.string(from: date), "20260903-070509")
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

    /// Unit text is locale-dependent ("MB" in English, "Mo" in French), so
    /// asserting English substrings breaks when the test host runs under a
    /// French language override. Instead, render the expected string with a
    /// formatter pinned to the single unit we expect — if `bytes(_:)` picks a
    /// different unit, the strings won't match in any locale.
    private func expectedBytes(_ count: Int64, unit: ByteCountFormatter.Units) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = unit
        return f.string(fromByteCount: count)
    }

    func testBytesZero() {
        XCTAssertEqual(SharedFormatters.bytes(0), expectedBytes(0, unit: .useKB))
    }

    func testBytesMegabyte() {
        // 1 MB (file/decimal style) → the MB unit.
        XCTAssertEqual(SharedFormatters.bytes(1_000_000),
                       expectedBytes(1_000_000, unit: .useMB))
    }

    func testBytesGigabyte() {
        XCTAssertEqual(SharedFormatters.bytes(1_000_000_000),
                       expectedBytes(1_000_000_000, unit: .useGB))
    }

    func testBytesTerabyte() {
        XCTAssertEqual(SharedFormatters.bytes(1_000_000_000_000),
                       expectedBytes(1_000_000_000_000, unit: .useTB))
    }

    func testBytesUsesAllowedUnitsNotBytes() {
        // The formatter only allows KB/MB/GB/TB — a small count must not render
        // in raw "bytes"; it rounds up to the smallest allowed unit (KB).
        XCTAssertEqual(SharedFormatters.bytes(2_048),
                       expectedBytes(2_048, unit: .useKB))
    }

    func testBytesConvenienceMatchesUnderlyingFormatter() {
        XCTAssertEqual(SharedFormatters.bytes(1_500_000),
                       SharedFormatters.fileBytes.string(fromByteCount: 1_500_000))
    }
}
