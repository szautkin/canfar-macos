// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

private let rangeSeparator = ".."

/// Parse a numeric range/comparison from user input.
/// Returns nil if input is empty or whitespace-only.
///
/// Examples:
///   "25"       → ParsedRange(value: 25, operand: .equals)
///   "< 25"     → ParsedRange(upper: 25, operand: .lessThan)
///   ">= 25"    → ParsedRange(lower: 25, operand: .greaterThanEquals)
///   "20..30"   → ParsedRange(lower: 20, upper: 30, operand: .range)
func parseRange(_ input: String) -> ParsedRange? {
    guard let raw = parseRangeRaw(input) else { return nil }

    if raw.operand == .range {
        return ParsedRange(
            lower: raw.lowerRaw.flatMap { Double($0) },
            upper: raw.upperRaw.flatMap { Double($0) },
            operand: raw.operand
        )
    }

    if let valueRaw = raw.valueRaw {
        return ParsedRange(value: Double(valueRaw), operand: raw.operand)
    }

    if let lowerRaw = raw.lowerRaw {
        return ParsedRange(lower: Double(lowerRaw), operand: raw.operand)
    }

    if let upperRaw = raw.upperRaw {
        return ParsedRange(upper: Double(upperRaw), operand: raw.operand)
    }

    return nil
}

/// Parse a range/comparison from user input, keeping raw string sides.
/// Needed for date ranges where sides like "2018-09-22 21:45" can't be parsed as numbers.
func parseRangeRaw(_ input: String) -> ParsedRangeRaw? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    // Range: "20..30" or "2018-09-22..2018-09-23"
    if let sepRange = trimmed.range(of: rangeSeparator) {
        return ParsedRangeRaw(
            lowerRaw: String(trimmed[trimmed.startIndex..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces),
            upperRaw: String(trimmed[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces),
            operand: .range
        )
    }

    // Comparison operators (check two-char before one-char)
    let opMap: [(prefix: String, operand: Operand, side: String)] = [
        ("<=", .lessThanEquals, "upper"),
        (">=", .greaterThanEquals, "lower"),
        ("<", .lessThan, "upper"),
        (">", .greaterThan, "lower"),
    ]

    for (prefix, operand, side) in opMap {
        if trimmed.hasPrefix(prefix) {
            let val = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if side == "lower" {
                return ParsedRangeRaw(lowerRaw: val, operand: operand)
            }
            return ParsedRangeRaw(upperRaw: val, operand: operand)
        }
    }

    // Plain value → EQUALS
    return ParsedRangeRaw(valueRaw: trimmed, operand: .equals)
}
