// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Build ADQL WHERE clauses for spectral constraints.
///
/// Coverage (energy.bounds.samples): overlap semantics
/// Numeric fields (sampleSize, bounds.width, restwav): standard range with metre normalization
/// Resolving power: standard range, dimensionless (no unit normalization)
enum SpectralBuilder {

    static func buildWhere(
        coverage: String,
        sampling: String,
        resolvingPower: String,
        bandpassWidth: String,
        restFrameEnergy: String
    ) -> [String] {
        var clauses: [String] = []

        if let clause = buildCoverageClause(coverage) {
            clauses.append(clause)
        }

        if let clause = buildSpectralNumericClause(sampling, column: SpectralTAPColumns.sampleSize) {
            clauses.append(clause)
        }

        if let clause = buildSpectralNumericClause(bandpassWidth, column: SpectralTAPColumns.boundsWidth) {
            clauses.append(clause)
        }

        if let clause = buildSpectralNumericClause(restFrameEnergy, column: SpectralTAPColumns.restwav) {
            clauses.append(clause)
        }

        if let clause = buildDimensionlessClause(resolvingPower, column: SpectralTAPColumns.resolvingPower) {
            clauses.append(clause)
        }

        return clauses
    }

    // MARK: - Coverage (Overlap Semantics)

    private static func buildCoverageClause(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let lowerCol = SpectralTAPColumns.boundsLower
        let upperCol = SpectralTAPColumns.boundsUpper
        guard let raw = parseRangeRaw(trimmed) else { return nil }

        switch raw.operand {
        case .range:
            guard let lowerRaw = raw.lowerRaw, let upperRaw = raw.upperRaw else { return nil }
            let lSuffix = extractSpectralSuffix(lowerRaw).suffix
            let uSuffix = extractSpectralSuffix(upperRaw).suffix
            let inherited = lSuffix ?? uSuffix
            guard let valA = try? normalizeToMetres(lowerRaw, inheritedSuffix: inherited),
                  let valB = try? normalizeToMetres(upperRaw, inheritedSuffix: inherited) else { return nil }
            let lowerM = min(valA, valB)
            let upperM = max(valA, valB)
            return "\(lowerCol) <= \(upperM) AND \(lowerM) <= \(upperCol)"

        case .lessThan, .lessThanEquals:
            guard let upperRaw = raw.upperRaw,
                  let upperM = try? normalizeToMetres(upperRaw) else { return nil }
            return "\(lowerCol) <= \(upperM)"

        case .greaterThan, .greaterThanEquals:
            guard let lowerRaw = raw.lowerRaw,
                  let lowerM = try? normalizeToMetres(lowerRaw) else { return nil }
            return "\(lowerM) <= \(upperCol)"

        case .equals:
            guard let valueRaw = raw.valueRaw,
                  let m = try? normalizeToMetres(valueRaw) else { return nil }
            return "\(lowerCol) <= \(m) AND \(m) <= \(upperCol)"
        }
    }

    // MARK: - Spectral Numeric (Metre Normalization)

    private static func buildSpectralNumericClause(_ value: String, column: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let raw = parseRangeRaw(trimmed) else { return nil }

        switch raw.operand {
        case .range:
            guard let lowerRaw = raw.lowerRaw, let upperRaw = raw.upperRaw else { return nil }
            let lSuffix = extractSpectralSuffix(lowerRaw).suffix
            let uSuffix = extractSpectralSuffix(upperRaw).suffix
            let inherited = lSuffix ?? uSuffix
            guard let valA = try? normalizeToMetres(lowerRaw, inheritedSuffix: inherited),
                  let valB = try? normalizeToMetres(upperRaw, inheritedSuffix: inherited) else { return nil }
            return "\(column) >= \(min(valA, valB)) AND \(column) <= \(max(valA, valB))"

        case .lessThan:
            guard let upperRaw = raw.upperRaw, let val = try? normalizeToMetres(upperRaw) else { return nil }
            return "\(column) < \(val)"

        case .lessThanEquals:
            guard let upperRaw = raw.upperRaw, let val = try? normalizeToMetres(upperRaw) else { return nil }
            return "\(column) <= \(val)"

        case .greaterThan:
            guard let lowerRaw = raw.lowerRaw, let val = try? normalizeToMetres(lowerRaw) else { return nil }
            return "\(column) > \(val)"

        case .greaterThanEquals:
            guard let lowerRaw = raw.lowerRaw, let val = try? normalizeToMetres(lowerRaw) else { return nil }
            return "\(column) >= \(val)"

        case .equals:
            guard let valueRaw = raw.valueRaw, let val = try? normalizeToMetres(valueRaw) else { return nil }
            return "\(column) = \(val)"
        }
    }

    // MARK: - Dimensionless (Resolving Power)

    private static func buildDimensionlessClause(_ value: String, column: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let raw = parseRangeRaw(trimmed) else { return nil }

        switch raw.operand {
        case .range:
            guard let lowerRaw = raw.lowerRaw, let upperRaw = raw.upperRaw,
                  let lower = Double(lowerRaw), let upper = Double(upperRaw) else { return nil }
            return "\(column) >= \(lower) AND \(column) <= \(upper)"

        case .lessThan:
            guard let upperRaw = raw.upperRaw, let val = Double(upperRaw) else { return nil }
            return "\(column) < \(val)"

        case .lessThanEquals:
            guard let upperRaw = raw.upperRaw, let val = Double(upperRaw) else { return nil }
            return "\(column) <= \(val)"

        case .greaterThan:
            guard let lowerRaw = raw.lowerRaw, let val = Double(lowerRaw) else { return nil }
            return "\(column) > \(val)"

        case .greaterThanEquals:
            guard let lowerRaw = raw.lowerRaw, let val = Double(lowerRaw) else { return nil }
            return "\(column) >= \(val)"

        case .equals:
            guard let valueRaw = raw.valueRaw, let val = Double(valueRaw) else { return nil }
            return "\(column) = \(val)"
        }
    }
}
