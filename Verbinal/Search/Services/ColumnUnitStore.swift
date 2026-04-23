// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Persistence of per-column unit selections for multi-unit columns.
///
/// Mirrors ``ColumnVisibilityStore`` — same DI pattern, same namespacing
/// discipline. Tests should use ``InMemoryColumnUnitStore``; production uses
/// ``UserDefaultsColumnUnitStore``.
protocol ColumnUnitStore: Sendable {
    /// Stored unit id for `columnID`, or `nil` if the user hasn't chosen one
    /// (in which case the formatter's default applies).
    func selectedUnit(forColumnID columnID: String) -> String?

    /// Persist a unit choice for `columnID`.
    func setSelectedUnit(_ unitID: String, forColumnID columnID: String)

    /// Remove every stored unit selection.
    func clearAll()
}

/// `UserDefaults`-backed implementation. Uses a namespaced key prefix so
/// `clearAll()` can scope deletes safely. See ``UserDefaultsColumnVisibilityStore``
/// for rationale.
struct UserDefaultsColumnUnitStore: ColumnUnitStore, @unchecked Sendable {
    static let keyPrefix = "search.col.unit."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selectedUnit(forColumnID columnID: String) -> String? {
        defaults.string(forKey: Self.keyPrefix + columnID)
    }

    func setSelectedUnit(_ unitID: String, forColumnID columnID: String) {
        defaults.set(unitID, forKey: Self.keyPrefix + columnID)
    }

    func clearAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// In-memory store — useful in unit tests and previews.
final class InMemoryColumnUnitStore: ColumnUnitStore, @unchecked Sendable {
    private var storage: [String: String] = [:]

    init() {}

    func selectedUnit(forColumnID columnID: String) -> String? { storage[columnID] }
    func setSelectedUnit(_ unitID: String, forColumnID columnID: String) { storage[columnID] = unitID }
    func clearAll() { storage.removeAll() }
}
