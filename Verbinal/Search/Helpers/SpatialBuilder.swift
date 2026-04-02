// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Build ADQL WHERE clauses for spatial constraints.
///
/// Three modes:
///   1. Name match (resolver=NONE or no coords): `lower(target_name) LIKE '%value%'`
///   2. Resolved target: `INTERSECTS(CIRCLE('ICRS', ra, dec, radius), position_bounds) = 1`
///   3. Coordinate range: `INTERSECTS(RANGE_S2D(...), position_bounds) = 1`
enum SpatialBuilder {

    struct Params {
        var target: String
        var resolver: ResolverValue
        var resolverCoords: (ra: String, dec: String)?
        var pixelScale: String
    }

    static func buildWhere(_ params: Params) -> [String] {
        var clauses: [String] = []
        let targetTrimmed = params.target.trimmingCharacters(in: .whitespaces)

        if !targetTrimmed.isEmpty {
            // Check for coordinate range mode: "raLo..raHi decLo..decHi"
            if let range = parseCoordRange(targetTrimmed) {
                clauses.append(
                    "INTERSECTS( RANGE_S2D(\(range.raLo), \(range.raHi), \(range.decLo), \(range.decHi)), \(SpatialTAPColumns.positionBounds) ) = 1"
                )
            } else if params.resolver == .none || params.resolverCoords == nil {
                // Name match mode
                let escaped = escapeSql(targetTrimmed.lowercased())
                clauses.append(
                    "lower(\(SpatialTAPColumns.targetName)) LIKE '%\(escaped)%'"
                )
            } else if let coords = params.resolverCoords {
                // Resolved target mode
                guard let ra = Double(coords.ra), let dec = Double(coords.dec) else {
                    let escaped = escapeSql(targetTrimmed.lowercased())
                    clauses.append("lower(\(SpatialTAPColumns.targetName)) LIKE '%\(escaped)%'")
                    return clauses
                }

                // Check for custom radius after target name
                var radius = ADQL.defaultSearchRadius
                let parts = targetTrimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count > 1, let lastPart = parts.last {
                    let parsed = parseRadius(lastPart)
                    if parsed > 0 {
                        radius = parsed
                    }
                }

                clauses.append(
                    "INTERSECTS( CIRCLE('ICRS', \(ra), \(dec), \(radius)), \(SpatialTAPColumns.positionBounds) ) = 1"
                )
            }
        }

        // Pixel scale
        let pixelTrimmed = params.pixelScale.trimmingCharacters(in: .whitespaces)
        if !pixelTrimmed.isEmpty, let clause = buildPixelScaleClause(pixelTrimmed) {
            clauses.append(clause)
        }

        return clauses
    }

    // MARK: - Private

    private static func parseCoordRange(_ input: String) -> (raLo: Double, raHi: Double, decLo: Double, decHi: Double)? {
        let parts = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count == 2,
              parts[0].contains(".."), parts[1].contains("..") else { return nil }

        let raParts = parts[0].components(separatedBy: "..")
        let decParts = parts[1].components(separatedBy: "..")
        guard raParts.count == 2, decParts.count == 2 else { return nil }

        guard let raLo = Double(raParts[0]), let raHi = Double(raParts[1]),
              let decLo = Double(decParts[0]), let decHi = Double(decParts[1]) else { return nil }

        return (raLo, raHi, decLo, decHi)
    }

    private static func parseRadius(_ input: String) -> Double {
        var trimmed = input.trimmingCharacters(in: .whitespaces)
        trimmed = trimmed.replacingOccurrences(of: "'", with: "arcmin")

        let pattern = try! NSRegularExpression(pattern: #"([0-9.eE+-]+)\s*(arcmin|arcsec|deg)?$"#, options: .caseInsensitive)
        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = pattern.firstMatch(in: trimmed, range: nsRange),
              let valueRange = Range(match.range(at: 1), in: trimmed),
              let value = Double(trimmed[valueRange]) else {
            return ADQL.defaultSearchRadius
        }

        if match.range(at: 2).location != NSNotFound,
           let unitRange = Range(match.range(at: 2), in: trimmed) {
            let unit = String(trimmed[unitRange]).lowercased()
            if unit == "arcmin" { return value / 60 }
            if unit == "arcsec" { return value / 3600 }
        }
        // "deg" or no unit → already degrees
        return value
    }

    private static func buildPixelScaleClause(_ value: String) -> String? {
        let column = SpatialTAPColumns.sampleSize
        guard let raw = parseRangeRaw(value) else { return nil }

        switch raw.operand {
        case .range:
            guard let lowerRaw = raw.lowerRaw, let upperRaw = raw.upperRaw,
                  let lower = try? normalizePixelScaleToDegrees(lowerRaw),
                  let upper = try? normalizePixelScaleToDegrees(upperRaw) else { return nil }
            return "\(column) >= \(lower) AND \(column) <= \(upper)"
        case .lessThan:
            guard let upperRaw = raw.upperRaw, let upper = try? normalizePixelScaleToDegrees(upperRaw) else { return nil }
            return "\(column) < \(upper)"
        case .lessThanEquals:
            guard let upperRaw = raw.upperRaw, let upper = try? normalizePixelScaleToDegrees(upperRaw) else { return nil }
            return "\(column) <= \(upper)"
        case .greaterThan:
            guard let lowerRaw = raw.lowerRaw, let lower = try? normalizePixelScaleToDegrees(lowerRaw) else { return nil }
            return "\(column) > \(lower)"
        case .greaterThanEquals:
            guard let lowerRaw = raw.lowerRaw, let lower = try? normalizePixelScaleToDegrees(lowerRaw) else { return nil }
            return "\(column) >= \(lower)"
        case .equals:
            guard let valueRaw = raw.valueRaw, let val = try? normalizePixelScaleToDegrees(valueRaw) else { return nil }
            return "\(column) = \(val)"
        }
    }
}
