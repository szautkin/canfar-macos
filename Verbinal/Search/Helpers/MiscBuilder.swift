// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Build ADQL WHERE clauses for miscellaneous constraints:
/// intent, public-only, data release date.
enum MiscBuilder {

    /// Build intent clause: `Observation.intent = 'science' | 'calibration'`
    static func buildIntentClause(_ intent: IntentValue) -> String? {
        switch intent {
        case .science:
            return "Observation.intent = 'science'"
        case .calibration:
            return "Observation.intent = 'calibration'"
        case .any:
            return nil
        }
    }

    /// Build public-only clause: `Plane.dataRelease <= '<today ISO>'`
    static func buildPublicOnlyClause(_ publicOnly: Bool) -> String? {
        guard publicOnly else { return nil }
        let today = SharedFormatters.yyyyMMddUTC.string(from: Date())
        return "Plane.dataRelease <= '\(today)'"
    }

    /// Build data release date clause.
    static func buildDataReleaseClause(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let column = "Plane.dataRelease"
        guard let raw = parseRangeRaw(trimmed) else { return nil }

        switch raw.operand {
        case .range:
            guard let lowerRaw = raw.lowerRaw, let upperRaw = raw.upperRaw else { return nil }
            let lower = toTimestamp(lowerRaw)
            let upper = toTimestamp(upperRaw)
            return "\(column) >= '\(lower)' AND \(column) <= '\(upper)'"

        case .lessThan:
            guard let upperRaw = raw.upperRaw else { return nil }
            return "\(column) < '\(toTimestamp(upperRaw))'"

        case .lessThanEquals:
            guard let upperRaw = raw.upperRaw else { return nil }
            return "\(column) <= '\(toTimestamp(upperRaw))'"

        case .greaterThan:
            guard let lowerRaw = raw.lowerRaw else { return nil }
            return "\(column) > '\(toTimestamp(lowerRaw))'"

        case .greaterThanEquals:
            guard let lowerRaw = raw.lowerRaw else { return nil }
            return "\(column) >= '\(toTimestamp(lowerRaw))'"

        case .equals:
            guard let valueRaw = raw.valueRaw else { return nil }
            if let expanded = try? expandSingleDateToRange(valueRaw) {
                let lower = formatISO(mjdToDate(expanded.lower))
                let upper = formatISO(mjdToDate(expanded.upper))
                return "\(column) >= '\(lower)' AND \(column) <= '\(upper)'"
            }
            return "\(column) = '\(toTimestamp(valueRaw))'"
        }
    }

    // MARK: - Private

    private static func toTimestamp(_ dateStr: String) -> String {
        let trimmed = dateStr.trimmingCharacters(in: .whitespaces)

        // If numeric (MJD/JD), convert to ISO
        if Double(trimmed) != nil, trimmed.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil,
           let mjd = try? dateToMJDValue(trimmed) {
            return formatISO(mjdToDate(mjd))
        }

        // Already ISO-like; normalize separator
        return trimmed.replacingOccurrences(of: "T", with: " ")
    }

    /// ADQL timestamp literal. POSIX locale: a fixed format must not
    /// follow the user's calendar (a Buddhist-calendar Mac would emit 2569).
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func formatISO(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}
