// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ColumnVisibilityStoreTests: XCTestCase {

    // MARK: - InMemory adapter

    func testInMemoryStoreUnsetIsFalse() {
        let store = InMemoryColumnVisibilityStore()
        XCTAssertFalse(store.isVisibilitySet(forID: "collection"))
    }

    func testInMemoryStoreSetAndGet() {
        let store = InMemoryColumnVisibilityStore()
        store.setVisible(true, forID: "collection")
        XCTAssertTrue(store.isVisibilitySet(forID: "collection"))
        XCTAssertTrue(store.visibility(forID: "collection"))

        store.setVisible(false, forID: "collection")
        XCTAssertTrue(store.isVisibilitySet(forID: "collection"))
        XCTAssertFalse(store.visibility(forID: "collection"))
    }

    func testInMemoryStoreClearAll() {
        let store = InMemoryColumnVisibilityStore()
        store.setVisible(true, forID: "a")
        store.setVisible(false, forID: "b")
        store.clearAll()
        XCTAssertFalse(store.isVisibilitySet(forID: "a"))
        XCTAssertFalse(store.isVisibilitySet(forID: "b"))
    }

    // MARK: - UserDefaults adapter (isolated suite)

    private func makeIsolatedUserDefaults() -> UserDefaults {
        // A per-test suite so we don't pollute the app's UserDefaults and
        // tests can't contaminate each other.
        let name = "ColumnVisibilityStoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    func testUserDefaultsRoundTrip() {
        let defaults = makeIsolatedUserDefaults()
        let store = UserDefaultsColumnVisibilityStore(defaults: defaults)

        XCTAssertFalse(store.isVisibilitySet(forID: "collection"))
        store.setVisible(true, forID: "collection")
        XCTAssertTrue(store.isVisibilitySet(forID: "collection"))
        XCTAssertTrue(store.visibility(forID: "collection"))
    }

    func testUserDefaultsClearAllScopedToPrefix() {
        let defaults = makeIsolatedUserDefaults()
        defaults.set("unrelated", forKey: "some.other.key")
        let store = UserDefaultsColumnVisibilityStore(defaults: defaults)

        store.setVisible(true, forID: "collection")
        store.setVisible(false, forID: "filter")
        store.clearAll()

        XCTAssertFalse(store.isVisibilitySet(forID: "collection"))
        XCTAssertFalse(store.isVisibilitySet(forID: "filter"))
        // The unrelated key must survive.
        XCTAssertEqual(defaults.string(forKey: "some.other.key"), "unrelated")
    }

    // MARK: - Integration with SearchResultColumns

    func testApplyPersistedVisibilityOverridesDefault() {
        let store = InMemoryColumnVisibilityStore()
        // Hide "collection" even though it's in defaultVisibleKeys.
        store.setVisible(false, forID: "collection")

        var columns = SearchResultColumns(
            headers: ["\"Collection\"", "\"Target Name\""],
            sampleRows: [["JWST", "M31"]]
        )
        columns.applyPersistedVisibility(store: store)

        XCTAssertEqual(columns.column(id: "collection")?.visible, false)
        // targetname has no override — default policy applies (visible=true).
        XCTAssertEqual(columns.column(id: "targetname")?.visible, true)
    }

    func testPersistVisibilityWritesAllColumns() {
        let store = InMemoryColumnVisibilityStore()
        var columns = SearchResultColumns(
            headers: ["\"Collection\"", "\"Foo\""],
            sampleRows: [["JWST", "bar"]]
        )
        columns.persistVisibility(store: store)

        XCTAssertTrue(store.isVisibilitySet(forID: "collection"))
        XCTAssertTrue(store.isVisibilitySet(forID: "foo"))
        // "Foo" is not in default-visible set, so persisted value is false.
        XCTAssertEqual(store.visibility(forID: "foo"), false)
        XCTAssertEqual(store.visibility(forID: "collection"), true)
    }
}
