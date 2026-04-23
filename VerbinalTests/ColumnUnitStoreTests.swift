// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ColumnUnitStoreTests: XCTestCase {

    // MARK: - InMemory adapter

    func testInMemoryStoreUnsetIsNil() {
        let store = InMemoryColumnUnitStore()
        XCTAssertNil(store.selectedUnit(forColumnID: "ra(j20000)"))
    }

    func testInMemoryStoreSetAndGet() {
        let store = InMemoryColumnUnitStore()
        store.setSelectedUnit("hms", forColumnID: "ra(j20000)")
        XCTAssertEqual(store.selectedUnit(forColumnID: "ra(j20000)"), "hms")

        store.setSelectedUnit("degrees", forColumnID: "ra(j20000)")
        XCTAssertEqual(store.selectedUnit(forColumnID: "ra(j20000)"), "degrees")
    }

    func testInMemoryStoreClearAll() {
        let store = InMemoryColumnUnitStore()
        store.setSelectedUnit("nm", forColumnID: "minwavelength")
        store.setSelectedUnit("mjd", forColumnID: "startdate")
        store.clearAll()
        XCTAssertNil(store.selectedUnit(forColumnID: "minwavelength"))
        XCTAssertNil(store.selectedUnit(forColumnID: "startdate"))
    }

    // MARK: - UserDefaults adapter (isolated suite)

    private func makeIsolatedUserDefaults() -> UserDefaults {
        let name = "ColumnUnitStoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    func testUserDefaultsRoundTrip() {
        let defaults = makeIsolatedUserDefaults()
        let store = UserDefaultsColumnUnitStore(defaults: defaults)

        XCTAssertNil(store.selectedUnit(forColumnID: "inttime"))
        store.setSelectedUnit("hours", forColumnID: "inttime")
        XCTAssertEqual(store.selectedUnit(forColumnID: "inttime"), "hours")
    }

    func testUserDefaultsClearAllScopedToPrefix() {
        let defaults = makeIsolatedUserDefaults()
        defaults.set("unrelated", forKey: "some.other.key")
        let store = UserDefaultsColumnUnitStore(defaults: defaults)

        store.setSelectedUnit("arcseconds", forColumnID: "pixelscale")
        store.setSelectedUnit("sq_deg", forColumnID: "fieldofview")
        store.clearAll()

        XCTAssertNil(store.selectedUnit(forColumnID: "pixelscale"))
        XCTAssertNil(store.selectedUnit(forColumnID: "fieldofview"))
        // Unrelated key survives.
        XCTAssertEqual(defaults.string(forKey: "some.other.key"), "unrelated")
    }

    func testUserDefaultsKeyPrefixIsStable() {
        // Regression guard — the key prefix is part of the user-data
        // on-disk format. Changing it invalidates every persisted selection,
        // so this assertion ensures we notice that change in review.
        XCTAssertEqual(UserDefaultsColumnUnitStore.keyPrefix, "search.col.unit.")
    }

    // MARK: - Integration with SearchResultsModel

    @MainActor
    func testLoadHydratesFromStoreOnlyForColumnsPresent() {
        let store = InMemoryColumnUnitStore()
        store.setSelectedUnit("degrees", forColumnID: "ra(j20000)")
        store.setSelectedUnit("kev",     forColumnID: "minwavelength")  // not in schema

        let model = SearchResultsModel(unitStore: store)
        let headers = ["\"RA (J2000.0)\""]
        let rows = [["229.638423456"]]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 10)

        XCTAssertEqual(model.selectedUnit(for: "ra(j20000)"), "degrees")
        // The minwavelength pre-selection must not leak into a result set
        // that doesn't include that column.
        XCTAssertNil(model.selectedUnit(for: "minwavelength").flatMap { $0 == "kev" ? "kev" : nil })
    }

    @MainActor
    func testSetUnitPersistsThroughStore() {
        let store = InMemoryColumnUnitStore()
        let model = SearchResultsModel(unitStore: store)
        let headers = ["\"RA (J2000.0)\""]
        let rows = [["229.638423456"]]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 10)

        model.setUnit(columnID: "ra(j20000)", unitID: "degrees")
        XCTAssertEqual(store.selectedUnit(forColumnID: "ra(j20000)"), "degrees")
    }
}
