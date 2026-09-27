// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What is news between two polls of sessions or batch jobs.
struct StatusTransitions {
    /// id → status at the previous poll; nil before the first one.
    let previous: [String: String]?
    /// id → status now.
    let current: [String: String]

    /// Anything appeared, vanished, or changed status. The first poll is
    /// not a change — there was nothing to compare with.
    var changed: Bool {
        guard let previous else { return false }
        return previous != current
    }

    /// The items to announce: they reached a settled state since the last
    /// poll — either they were in flight then, or they appeared between the
    /// two polls (a job that started and failed inside one interval). On the
    /// first poll, nothing: what settled before the app looked is not news.
    func newlySettled<Item>(
        _ items: [Item],
        id: (Item) -> String,
        wasInFlight: (String) -> Bool,
        isSettled: (Item) -> Bool
    ) -> [Item] {
        guard let previous else { return [] }
        return items.filter { item in
            guard isSettled(item) else { return false }
            guard let before = previous[id(item)] else { return true }
            return wasInFlight(before)
        }
    }
}
