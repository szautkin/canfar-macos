// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Persistence of per-column visibility overrides for the search results table.
///
/// Abstracts the storage backend away from ``SearchResultColumns`` so tests can
/// inject an in-memory store and production code can't accidentally leak state
/// into global `UserDefaults`. Keys are per-column ids (``SearchResultColumn/id``).
protocol ColumnVisibilityStore: Sendable {
    /// True iff the user has ever explicitly set visibility for `id`.
    /// Returning false means "fall back to the default-visible policy".
    func isVisibilitySet(forID id: String) -> Bool

    /// The stored visibility for `id`. Undefined (implementation-dependent)
    /// if ``isVisibilitySet(forID:)`` returns false — callers should always
    /// guard the read with `isVisibilitySet`.
    func visibility(forID id: String) -> Bool

    /// Persist an explicit visibility value for `id`.
    func setVisible(_ visible: Bool, forID id: String)

    /// Remove every stored override. After calling, ``isVisibilitySet(forID:)``
    /// returns false for all ids and the default policy applies to future
    /// ``SearchResultColumns`` loads.
    func clearAll()
}

/// `UserDefaults`-backed implementation. Uses a single namespaced key prefix,
/// so `clearAll()` can scan & remove atomically without affecting unrelated
/// defaults entries.
///
/// `@unchecked Sendable` because `UserDefaults` is documented thread-safe by
/// Apple but not yet formally marked `Sendable`. Our callers touch this only
/// from `@MainActor`, so the audit is straightforward.
struct UserDefaultsColumnVisibilityStore: ColumnVisibilityStore, @unchecked Sendable {
    /// Namespaced so `clearAll` can scope its deletes safely. Anyone adding a
    /// new `UserDefaults` key must NOT start it with this prefix.
    static let keyPrefix = "search.col.visible."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isVisibilitySet(forID id: String) -> Bool {
        defaults.object(forKey: Self.keyPrefix + id) != nil
    }

    func visibility(forID id: String) -> Bool {
        defaults.bool(forKey: Self.keyPrefix + id)
    }

    func setVisible(_ visible: Bool, forID id: String) {
        defaults.set(visible, forKey: Self.keyPrefix + id)
    }

    func clearAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// In-memory store — useful in unit tests and previews. Not thread-safe;
/// ``SearchResultColumns`` callers operate on `@MainActor`, so this is fine
/// for their use case.
final class InMemoryColumnVisibilityStore: ColumnVisibilityStore, @unchecked Sendable {
    private var storage: [String: Bool] = [:]

    init() {}

    func isVisibilitySet(forID id: String) -> Bool { storage[id] != nil }
    func visibility(forID id: String) -> Bool { storage[id] ?? false }
    func setVisible(_ visible: Bool, forID id: String) { storage[id] = visible }
    func clearAll() { storage.removeAll() }
}
