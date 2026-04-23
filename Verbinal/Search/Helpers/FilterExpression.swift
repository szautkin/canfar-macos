// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Parsed form of a user-entered filter expression.
///
/// Two shapes:
///  • **Numeric comparison**: an optional prefix operator (`<`, `<=`, `>`,
///    `>=`, `=`) followed by a real number. Used on numeric-kind columns to
///    give CCDA-style range filtering.
///  • **Substring**: the fallback — matches anywhere in the cell's raw or
///    formatted text (case-insensitive).
///
/// The parser intentionally lives outside ``SearchResultsModel`` so it is
/// unit-testable without spinning up a full model.
enum FilterExpression: Equatable {
    enum Comparison: String, Equatable {
        case equal = "="
        case less = "<"
        case lessOrEqual = "<="
        case greater = ">"
        case greaterOrEqual = ">="

        func matches(_ value: Double, against threshold: Double) -> Bool {
            switch self {
            case .equal: return value == threshold
            case .less: return value < threshold
            case .lessOrEqual: return value <= threshold
            case .greater: return value > threshold
            case .greaterOrEqual: return value >= threshold
            }
        }
    }

    case numeric(Comparison, Double)
    case substring(String)

    // swiftlint:disable:next force_try
    private static let numericRegex = try! NSRegularExpression(
        pattern: #"^\s*(<=|>=|<|>|=)?\s*(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s*$"#
    )

    /// Parse a raw filter string.
    ///
    /// - Parameter raw: what the user typed.
    /// - Parameter numericEligible: if `true`, the parser attempts numeric
    ///   matching first and falls back to substring. If `false`, the result
    ///   is always `.substring` (for text-kind columns, where `"NGC"` should
    ///   remain a substring filter and not be rejected as non-numeric).
    /// - Returns: the parsed expression, or `nil` if the input is empty.
    static func parse(_ raw: String, numericEligible: Bool) -> FilterExpression? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if numericEligible {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = numericRegex.firstMatch(in: trimmed, range: range) {
                let opRange = match.range(at: 1)
                let numRange = match.range(at: 2)
                guard numRange.location != NSNotFound,
                      let swiftNumRange = Range(numRange, in: trimmed) else {
                    return .substring(trimmed.lowercased())
                }
                let numberString = String(trimmed[swiftNumRange])
                guard let value = Double(numberString), value.isFinite else {
                    return .substring(trimmed.lowercased())
                }
                let op: Comparison
                if opRange.location != NSNotFound,
                   let swiftOpRange = Range(opRange, in: trimmed),
                   let parsedOp = Comparison(rawValue: String(trimmed[swiftOpRange])) {
                    op = parsedOp
                } else {
                    op = .equal
                }
                return .numeric(op, value)
            }
        }
        return .substring(trimmed.lowercased())
    }
}
