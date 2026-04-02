// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One row from the caom2.enumfield data train query.
/// Contains values for all 7 data train columns plus a freshness flag.
struct DataTrainRow: Codable {
    /// Values for each of the 7 data train columns, in cascade order.
    let values: [String]

    /// Whether this instrument combination has been used recently.
    let fresh: Bool

    /// Get the value for a specific data train column by index.
    func value(at index: Int) -> String? {
        guard index >= 0, index < values.count else { return nil }
        let v = values[index]
        return v.isEmpty ? nil : v
    }
}
