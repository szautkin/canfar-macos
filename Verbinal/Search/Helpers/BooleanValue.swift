// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Canonical parser for boolean-ish strings that come back from CADC / TAP
/// responses and CSV exports.
///
/// Single source of truth for the truth-literal set. Formatters, comparators,
/// and column-kind inference all funnel through here so we can never drift
/// into three slightly-different definitions of "what looks true".
enum BooleanValue {
    /// Case-insensitive; lowercased before comparison.
    static let trueLiterals: Set<String> = ["true", "1", "t", "yes", "y"]
    static let falseLiterals: Set<String> = ["false", "0", "f", "no", "n"]

    /// Parse a raw string. Returns `nil` for anything not in the truth-literal
    /// sets — callers should decide whether to passthrough, reject, or
    /// fall-back to text comparison.
    static func parse(_ raw: String) -> Bool? {
        let lowered = raw.lowercased()
        if trueLiterals.contains(lowered) { return true }
        if falseLiterals.contains(lowered) { return false }
        return nil
    }

    /// True iff `raw` is recognised as either a true- or false-literal.
    static func looksBoolean(_ raw: String) -> Bool {
        parse(raw) != nil
    }
}
