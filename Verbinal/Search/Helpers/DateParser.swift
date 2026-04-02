// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// MARK: - Constants

/// Julian Date threshold: values above this are JD, below are MJD
private let jdThreshold = 2400000.5

/// MJD epoch offset (Unix epoch 1970-01-01 in MJD)
private let mjdUnixEpoch = 40587.0

/// Seconds per day
private let secondsPerDay = 86400.0

// MARK: - ISO Patterns (ordered by specificity — most specific first)

private let isoPatterns: [(pattern: NSRegularExpression, granularity: DateGranularity)] = {
    let defs: [(String, DateGranularity)] = [
        (#"^\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}:\d{2}\.\d+$"#, .millisecond),
        (#"^\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}:\d{2}$"#, .second),
        (#"^\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}$"#, .minute),
        (#"^\d{4}-\d{2}-\d{2}[T ]\d{1,2}$"#, .hour),
        (#"^\d{4}-\d{2}-\d{2}$"#, .day),
        (#"^\d{4}-\d{2}$"#, .month),
        (#"^\d{4}$"#, .year),
    ]
    return defs.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}()

/// Strict numeric pattern for JD/MJD detection
private let numericPattern = try! NSRegularExpression(
    pattern: #"^[+-]?(\d+\.?\d*|\d*\.?\d+)([eE][+-]?\d+)?$"#
)

// MARK: - Public API

/// Parse a single date string and detect its format (JD, MJD, or ISO).
func parseSingleDate(_ input: String) throws -> ParsedDate {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

    // Try ISO patterns first (most specific first)
    for (pattern, granularity) in isoPatterns {
        if pattern.firstMatch(in: trimmed, range: nsRange) != nil {
            let date = try parseISO(trimmed, granularity: granularity)
            return ParsedDate(date: date, format: .iso, granularity: granularity)
        }
    }

    // Try numeric: JD or MJD
    if let numeric = Double(trimmed),
       numericPattern.firstMatch(in: trimmed, range: nsRange) != nil {
        if numeric > jdThreshold {
            let mjd = numeric - 2400000.5
            return ParsedDate(date: mjdToDate(mjd), format: .jd, granularity: .millisecond)
        }
        return ParsedDate(date: mjdToDate(numeric), format: .mjd, granularity: .millisecond)
    }

    throw SearchError.parseError("Cannot parse date: \"\(trimmed)\"")
}

/// Parse a single date string and return its MJD value.
func dateToMJDValue(_ input: String) throws -> Double {
    let parsed = try parseSingleDate(input)
    switch parsed.format {
    case .jd:
        return Double(input.trimmingCharacters(in: .whitespaces))! - 2400000.5
    case .mjd:
        return Double(input.trimmingCharacters(in: .whitespaces))!
    case .iso:
        return dateToMJD(parsed.date)
    }
}

/// Expand a single date to an MJD range covering the full granularity.
/// E.g. "2018" → (lower: MJD(2018-01-01), upper: MJD(2019-01-01))
func expandSingleDateToRange(_ input: String) throws -> (lower: Double, upper: Double) {
    let parsed = try parseSingleDate(input)

    // Numeric dates are point values — no expansion
    if parsed.format == .jd || parsed.format == .mjd {
        let mjd = try dateToMJDValue(input)
        return (lower: mjd, upper: mjd)
    }

    let lower = dateToMJD(parsed.date)
    let upper = dateToMJD(addGranularity(parsed.date, granularity: parsed.granularity))
    return (lower: lower, upper: upper)
}

/// Expand a date preset to an MJD range string relative to now.
func expandDatePreset(_ preset: DatePresetValue) -> String? {
    guard preset != .none else { return nil }

    let now = Date()
    let upperMJD = dateToMJD(now)

    let calendar = Calendar(identifier: .gregorian)
    let past: Date
    switch preset {
    case .past24Hours:
        past = calendar.date(byAdding: .hour, value: -24, to: now)!
    case .pastWeek:
        past = calendar.date(byAdding: .day, value: -7, to: now)!
    case .pastMonth:
        past = calendar.date(byAdding: .month, value: -1, to: now)!
    case .none:
        return nil
    }

    let lowerMJD = dateToMJD(past)
    return "\(lowerMJD)..\(upperMJD)"
}

// MARK: - Conversion Utilities

/// Convert a Date to MJD value.
func dateToMJD(_ date: Date) -> Double {
    return date.timeIntervalSince1970 / secondsPerDay + mjdUnixEpoch
}

/// Convert MJD to a Date (UTC).
private func mjdToDate(_ mjd: Double) -> Date {
    return Date(timeIntervalSince1970: (mjd - mjdUnixEpoch) * secondsPerDay)
}

/// Parse an ISO date string to a UTC Date, normalizing partial formats.
private func parseISO(_ input: String, granularity: DateGranularity) throws -> Date {
    var normalized = input.replacingOccurrences(of: " ", with: "T")

    // Pad single-digit hours (e.g. "T9:" → "T09:")
    if let range = normalized.range(of: "T\\d:", options: .regularExpression) {
        let hourChar = normalized[normalized.index(range.lowerBound, offsetBy: 1)]
        normalized = normalized.replacingCharacters(in: range, with: "T0\(hourChar):")
    }

    switch granularity {
    case .year:
        normalized = "\(normalized)-01-01T00:00:00.000Z"
    case .month:
        normalized = "\(normalized)-01T00:00:00.000Z"
    case .day:
        normalized = "\(normalized)T00:00:00.000Z"
    case .hour:
        normalized = "\(normalized):00:00.000Z"
    case .minute:
        normalized = "\(normalized):00.000Z"
    case .second:
        normalized = "\(normalized).000Z"
    case .millisecond:
        normalized = "\(normalized)Z"
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: normalized) else {
        throw SearchError.parseError("Invalid ISO date: \"\(input)\"")
    }
    return date
}

/// Add one unit of granularity to a Date (UTC).
private func addGranularity(_ date: Date, granularity: DateGranularity) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    switch granularity {
    case .year:
        return calendar.date(byAdding: .year, value: 1, to: date)!
    case .month:
        return calendar.date(byAdding: .month, value: 1, to: date)!
    case .day:
        return calendar.date(byAdding: .day, value: 1, to: date)!
    case .hour:
        return calendar.date(byAdding: .hour, value: 1, to: date)!
    case .minute:
        return calendar.date(byAdding: .minute, value: 1, to: date)!
    case .second:
        return calendar.date(byAdding: .second, value: 1, to: date)!
    case .millisecond:
        return date.addingTimeInterval(0.001)
    }
}
