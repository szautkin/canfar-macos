// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The marks of one file (and extension) every device knows, as the sync
/// carries them (plan 36 4.2): its identity, and its marks.
struct MarkSet: Codable, Equatable, Sendable {
    var target: String
    var marks: [Mark]

    /// When its marks last changed: the newest of them.
    var changedAt: Date {
        marks.map { $0.modifiedAt ?? $0.createdAt }.max() ?? .distantPast
    }
}
