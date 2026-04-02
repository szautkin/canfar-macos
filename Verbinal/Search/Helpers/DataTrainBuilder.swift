// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Build ADQL WHERE clauses for data train (enumerated field) constraints.
///
/// Single value:   `column = 'value'`
/// Multiple values: `( column = 'a' OR column = 'b' OR ... )`
enum DataTrainBuilder {

    static func buildWhere(selections: [String: [String]]) -> [String] {
        var clauses: [String] = []

        for (utype, values) in selections {
            guard !values.isEmpty else { continue }

            guard let column = ADQL.dataTrainObservationColumns[utype] else { continue }

            if values.count == 1 {
                clauses.append("\(column) = '\(escapeSql(values[0]))'")
            } else {
                let ors = values
                    .map { "\(column) = '\(escapeSql($0))'" }
                    .joined(separator: " OR ")
                clauses.append("( \(ors) )")
            }
        }

        return clauses
    }
}
