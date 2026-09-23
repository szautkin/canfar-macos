// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

private let rangeSeparator = ".."

/// Parse a range/comparison from user input, keeping raw string sides so
/// each builder converts them (numbers, dates like "2018-09-22 21:45", …).
/// Returns nil if input is empty or whitespace-only.
///
/// Examples:
///   "25"       → valueRaw "25", `.equals`
///   "< 25"     → upperRaw "25", `.lessThan`
///   ">= 25"    → lowerRaw "25", `.greaterThanEquals`
///   "20..30"   → lowerRaw "20", upperRaw "30", `.range`
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
