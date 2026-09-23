// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
@testable import Verbinal

/// In-memory column-unit store for tests. Not thread-safe;
/// ``SearchResultColumns`` callers operate on `@MainActor`.
final class InMemoryColumnUnitStore: ColumnUnitStore, @unchecked Sendable {
    private var storage: [String: String] = [:]

    init() {}

    func selectedUnit(forColumnID columnID: String) -> String? { storage[columnID] }
    func setSelectedUnit(_ unitID: String, forColumnID columnID: String) { storage[columnID] = unitID }
    func clearAll() { storage.removeAll() }
}

/// In-memory column-visibility store for tests. Not thread-safe;
/// ``SearchResultColumns`` callers operate on `@MainActor`.
final class InMemoryColumnVisibilityStore: ColumnVisibilityStore, @unchecked Sendable {
    private var storage: [String: Bool] = [:]

    init() {}

    func isVisibilitySet(forID id: String) -> Bool { storage[id] != nil }
    func visibility(forID id: String) -> Bool { storage[id] ?? false }
    func setVisible(_ visible: Bool, forID id: String) { storage[id] = visible }
    func clearAll() { storage.removeAll() }
}
