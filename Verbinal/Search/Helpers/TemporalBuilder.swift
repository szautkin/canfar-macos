// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Build ADQL WHERE clauses for temporal constraints.
///
/// Date clause:  `INTERSECTS( INTERVAL( <mjdLower>, <mjdUpper> ), Plane.time_bounds_samples ) = 1`
/// Time clause:  `Plane.time_exposure >= <lower> AND Plane.time_exposure <= <upper>`
enum TemporalBuilder {

    /// Build all temporal WHERE clauses from form params.
    static func buildWhere(
        date: String,
        preset: DatePresetValue,
        exposure: String,
        timeSpan: String
    ) -> [String] {
        var clauses: [String] = []

        if let dateClause = buildDateClause(dateValue: date, preset: preset) {
            clauses.append(dateClause)
        }

        if let exposureClause = buildTimeClause(value: exposure, utype: .exposure) {
            clauses.append(exposureClause)
        }

        if let widthClause = buildTimeClause(value: timeSpan, utype: .boundsWidth) {
            clauses.append(widthClause)
        }

        return clauses
    }

    // MARK: - Date Clause

    private enum TimeUtype {
        case exposure
        case boundsWidth

        var column: String {
            switch self {
            case .exposure: return TemporalTAPColumns.timeExposure
            case .boundsWidth: return TemporalTAPColumns.timeBoundsWidth
            }
        }

        var defaultUnit: String {
            switch self {
            case .exposure: return "s"
            case .boundsWidth: return "d"
            }
        }
    }

    private static func buildDateClause(dateValue: String, preset: DatePresetValue) -> String? {
        let effectiveInput = dateValue.trimmingCharacters(in: .whitespaces)
        var inputToProcess: String?

        if !effectiveInput.isEmpty {
            inputToProcess = effectiveInput
        } else if let presetRange = expandDatePreset(preset) {
            inputToProcess = presetRange
        }

        guard let input = inputToProcess else { return nil }

        let column = TemporalTAPColumns.timeBoundsSamples
        guard let raw = parseRangeRaw(input) else { return nil }

        var lower: Double
        var upper: Double

        switch raw.operand {
        case .range:
            guard let lowerRaw = raw.lowerRaw, let upperRaw = raw.upperRaw else { return nil }
            do {
                lower = try dateToMJDValue(lowerRaw)
                upper = try dateToMJDValue(upperRaw)
            } catch { return nil }

        case .lessThan, .lessThanEquals:
            guard let upperRaw = raw.upperRaw else { return nil }
            do {
                let expanded = try expandSingleDateToRange(upperRaw)
                lower = 0
                upper = raw.operand == .lessThan ? expanded.lower : expanded.upper
            } catch { return nil }

        case .greaterThan, .greaterThanEquals:
            guard let lowerRaw = raw.lowerRaw else { return nil }
            do {
                let expanded = try expandSingleDateToRange(lowerRaw)
                lower = raw.operand == .greaterThan ? expanded.upper : expanded.lower
                upper = 1e8 // far future MJD
            } catch { return nil }

        case .equals:
            guard let valueRaw = raw.valueRaw else { return nil }
            do {
                let expanded = try expandSingleDateToRange(valueRaw)
                lower = expanded.lower
                upper = expanded.upper
            } catch { return nil }
        }

        return "INTERSECTS( INTERVAL( \(lower), \(upper) ), \(column) ) = 1"
    }

    // MARK: - Time Clause

    private static func buildTimeClause(value: String, utype: TimeUtype) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let column = utype.column
        let defaultUnit = utype.defaultUnit
        guard let raw = parseRangeRaw(trimmed) else { return nil }

        switch raw.operand {
        case .range:
            guard let lowerRaw = raw.lowerRaw, let upperRaw = raw.upperRaw else { return nil }
            let lSuffix = extractTimeSuffix(lowerRaw).suffix
            let uSuffix = extractTimeSuffix(upperRaw).suffix
            let inherited = lSuffix ?? uSuffix
            guard let lower = try? normalizeTimeValue(lowerRaw, defaultUnit: defaultUnit, inheritedSuffix: inherited),
                  let upper = try? normalizeTimeValue(upperRaw, defaultUnit: defaultUnit, inheritedSuffix: inherited) else { return nil }
            return "\(column) >= \(lower) AND \(column) <= \(upper)"

        case .lessThan:
            guard let upperRaw = raw.upperRaw,
                  let val = try? normalizeTimeValue(upperRaw, defaultUnit: defaultUnit) else { return nil }
            return "\(column) < \(val)"

        case .lessThanEquals:
            guard let upperRaw = raw.upperRaw,
                  let val = try? normalizeTimeValue(upperRaw, defaultUnit: defaultUnit) else { return nil }
            return "\(column) <= \(val)"

        case .greaterThan:
            guard let lowerRaw = raw.lowerRaw,
                  let val = try? normalizeTimeValue(lowerRaw, defaultUnit: defaultUnit) else { return nil }
            return "\(column) > \(val)"

        case .greaterThanEquals:
            guard let lowerRaw = raw.lowerRaw,
                  let val = try? normalizeTimeValue(lowerRaw, defaultUnit: defaultUnit) else { return nil }
            return "\(column) >= \(val)"

        case .equals:
            guard let valueRaw = raw.valueRaw,
                  let val = try? normalizeTimeValue(valueRaw, defaultUnit: defaultUnit) else { return nil }
            return "\(column) = \(val)"
        }
    }
}
