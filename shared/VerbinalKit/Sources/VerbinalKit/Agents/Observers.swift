// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Who is listening for `Event`s, and telling them — the one way the
/// ledger, the change log and the decision log each let the session log
/// hear them, without knowing it (plan 23).
public final class Observers<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (Event) -> Void] = [:]

    public init() {}

    /// Calls `observer` with every event until `stopObserving`, on the
    /// thread the event happens on: hand heavy work off.
    @discardableResult
    public func observe(_ observer: @escaping @Sendable (Event) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = observer }
        return id
    }

    public func stopObserving(_ id: UUID) {
        lock.withLock { observers[id] = nil }
    }

    public func notify(_ event: Event) {
        for observer in lock.withLock({ Array(observers.values) }) { observer(event) }
    }
}
