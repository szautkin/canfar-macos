// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class SearchFormStateTests: XCTestCase {

    // MARK: - hasValues

    func testHasValuesFalseOnFreshState() {
        let state = SearchFormState()
        XCTAssertFalse(state.hasValues, "A freshly constructed form should report no values.")
    }

    func testHasValuesFalseAfterReset() {
        let state = SearchFormState()
        // Populate a spread of fields, then reset.
        state.observationID = "obs123"
        state.target = "M31"
        state.spectralCoverage = "400..700nm"
        state.intent = .science
        state.publicOnly = true
        state.datePreset = .pastWeek
        state.selectedCollections = ["JWST"]
        state.selectedBands = ["Optical"]
        XCTAssertTrue(state.hasValues, "Populated form should report values before reset.")

        state.reset()
        XCTAssertFalse(state.hasValues, "Reset form should report no values.")
    }

    func testHasValuesTrueForTarget() {
        let state = SearchFormState()
        state.target = "M31"
        XCTAssertTrue(state.hasValues)
    }

    func testHasValuesTrueForSpectralCoverage() {
        let state = SearchFormState()
        state.spectralCoverage = "400..700nm"
        XCTAssertTrue(state.hasValues)
    }

    func testHasValuesTrueForSelectedCollections() {
        let state = SearchFormState()
        state.selectedCollections = ["JWST"]
        XCTAssertTrue(state.hasValues)
    }

    func testHasValuesTrueForIntent() {
        let state = SearchFormState()
        state.intent = .science
        XCTAssertTrue(state.hasValues)
    }

    func testHasValuesTrueForPublicOnly() {
        let state = SearchFormState()
        state.publicOnly = true
        XCTAssertTrue(state.hasValues)
    }

    func testHasValuesTrueForDatePreset() {
        let state = SearchFormState()
        state.datePreset = .pastMonth
        XCTAssertTrue(state.hasValues)
    }

    func testHasValuesTrueForPixelScale() {
        let state = SearchFormState()
        state.pixelScale = "0.5"
        XCTAssertTrue(state.hasValues)
    }

    func testHasValuesTrueForRestFrameEnergy() {
        let state = SearchFormState()
        state.restFrameEnergy = "5keV"
        XCTAssertTrue(state.hasValues)
    }
}
