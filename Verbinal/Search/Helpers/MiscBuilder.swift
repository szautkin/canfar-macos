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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let today = formatter.string(from: Date())
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
                let lowerDate = Date(timeIntervalSince1970: (expanded.lower - 40587) * 86400)
                let upperDate = Date(timeIntervalSince1970: (expanded.upper - 40587) * 86400)
                return "\(column) >= '\(formatISO(lowerDate))' AND \(column) <= '\(formatISO(upperDate))'"
            }
            return "\(column) = '\(toTimestamp(valueRaw))'"
        }
    }

    // MARK: - Private

    private static func toTimestamp(_ dateStr: String) -> String {
        let trimmed = dateStr.trimmingCharacters(in: .whitespaces)

        // If numeric (MJD/JD), convert to ISO
        if let num = Double(trimmed), trimmed.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil {
            if let mjd = try? dateToMJDValue(trimmed) {
                let date = Date(timeIntervalSince1970: (mjd - 40587) * 86400)
                return formatISO(date)
            }
            let _ = num // suppress unused warning
        }

        // Already ISO-like; normalize separator
        return trimmed.replacingOccurrences(of: "T", with: " ")
    }

    private static func formatISO(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
