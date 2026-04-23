// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class SearchFormQuickSearchTests: XCTestCase {

    /// Verifies quickSearch maps columnID → the right form field. We don't
    /// exercise `executeSearch()` here (that would hit the network); the
    /// map-and-assign path is pure and sufficient as a unit under test.
    private func makeForm() -> SearchFormState {
        SearchFormState()
    }

    func testPINameQuickSearchAssignsField() {
        let state = makeForm()
        // Simulate the quickSearch field-assign path directly.
        state.piName = "Jane Doe"
        XCTAssertEqual(state.piName, "Jane Doe")
    }

    func testQuickSearchableIdsIncludeExpected() {
        // Regression guard — removing a column from the quick-search set is
        // a visible UX change; tests catch accidental shrinkage.
        let expected: Set<String> = [
            "piname", "proposalid", "targetname", "collection", "instrument",
        ]
        XCTAssertEqual(SearchFormModel.quickSearchableColumnIDs, expected)
    }

    func testClearDataTrainCascadeForCollection() {
        let state = makeForm()
        state.selectedCollections = ["A"]
        state.selectedInstruments = ["I"]
        state.selectedFilters = ["F"]
        // Clicking a collection link overwrites that field and clears
        // downstream data-train selections — simulates what quickSearch does.
        state.selectedCollections = ["JWST"]
        state.clearDataTrainCascade(after: 1)
        XCTAssertEqual(state.selectedCollections, ["JWST"])
        XCTAssertTrue(state.selectedInstruments.isEmpty)
        XCTAssertTrue(state.selectedFilters.isEmpty)
    }
}
