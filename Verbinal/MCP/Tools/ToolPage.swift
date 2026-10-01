// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

/// One page of a long answer: `limit` entries from `cursor`, and the cursor
/// of the page after while more remain — so a list of ten thousand never
/// comes back whole.
struct ToolPage: Equatable {
    static let defaultLimit = 200
    static let maxLimit = 500

    let range: Range<Int>
    /// What to pass back as `cursor`; nil on the last page.
    let next: String?

    init(total: Int, cursor: String?, limit: Int?) {
        let start = min(max(Int(cursor ?? "") ?? 0, 0), total)
        let end = min(start + min(max(limit ?? Self.defaultLimit, 1), Self.maxLimit), total)
        range = start..<end
        next = end < total ? String(end) : nil
    }
}
