// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// How long session logs are kept: 10 days, and never more than 10 MB in
/// all (the person, 2026-09-30). A rule, not a setting — and only a rule:
/// the store does the deleting (plan 23 L4).
enum SessionLogRetention {
    static let keepFor: TimeInterval = 10 * 24 * 60 * 60
    static let maxTotalBytes = 10 * 1_048_576
    /// One session's most, so a busy one cannot take the whole allowance.
    static let maxSessionBytes = 2 * 1_048_576

    /// The rule, in words, for `list_session_logs` and the person's view.
    static let rule = "Session logs are kept 10 days, and never more than 10 MB in all; the oldest closed logs go first, never an open one."

    /// The logs the rule removes: every closed one older than `keepFor`,
    /// then the oldest closed ones while the rest are over `maxTotalBytes`.
    /// Never an open one.
    static func toRemove(_ logs: [StoredSessionLog], open: Set<UUID>, now: Date = Date()) -> [StoredSessionLog] {
        let closed = logs.filter { !open.contains($0.header.session) }.sorted { $0.lastAt < $1.lastAt }
        var removed = closed.filter { now.timeIntervalSince($0.lastAt) > keepFor }
        var total = logs.map(\.bytes).reduce(0, +) - removed.map(\.bytes).reduce(0, +)
        for log in closed where total > maxTotalBytes && !removed.contains(where: { $0.url == log.url }) {
            removed.append(log)
            total -= log.bytes
        }
        return removed
    }
}
