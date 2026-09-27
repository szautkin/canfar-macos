// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A value behind a lock, for test doubles that record what a `@Sendable`
/// closure saw — a `MockURLProtocol` handler, a progress callback on
/// URLSession's queue, a stubbed service. `NSLock.withLock` is the scoped
/// form that is safe to call from async code.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func set(_ newValue: Value) { lock.withLock { stored = newValue } }

    /// Reads or changes the value in one step under the lock.
    @discardableResult
    func withValue<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLock { try body(&stored) }
    }
}

extension Locked where Value == Int {
    /// Adds one and returns the new count.
    @discardableResult
    func increment() -> Int { withValue { $0 += 1; return $0 } }
}
