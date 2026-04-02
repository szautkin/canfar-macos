// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Escape single quotes for ADQL string literals.
func escapeSql(_ str: String) -> String {
    str.replacingOccurrences(of: "'", with: "''")
}

/// Build WHERE clauses for observation text constraint fields.
///
/// Wild fields (PI, proposal ID/title/keywords): `lower(col) LIKE '%value%'`
/// Exact fields (observation ID): `lower(col) = 'value'` (with `*` → `%` for wildcards)
enum ObservationBuilder {

    static func buildWhere(values: [String: String]) -> [String] {
        var clauses: [String] = []

        for (utype, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let column = ADQL.observationTAPColumns[utype] else { continue }

            let escaped = escapeSql(trimmed.lowercased())

            if ADQL.wildTextFields.contains(utype) {
                clauses.append("lower(\(column)) LIKE '%\(escaped)%'")
            } else if ADQL.exactTextFields.contains(utype) {
                if trimmed.contains("*") {
                    let pattern = escaped.replacingOccurrences(of: "*", with: "%")
                    clauses.append("lower(\(column)) LIKE '\(pattern)'")
                } else {
                    clauses.append("lower(\(column)) = '\(escaped)'")
                }
            }
        }

        return clauses
    }
}
