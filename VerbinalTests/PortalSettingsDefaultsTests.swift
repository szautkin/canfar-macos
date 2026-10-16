// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Plan 41 step 3: Settings ▸ Portal's GPU default is one or none.
final class PortalSettingsDefaultsTests: XCTestCase {
    private let staging = GPUOffer(options: Array(1...7))

    /// Staging's options have no 0: the picker had made the default 1 GPU
    /// the first time Settings opened.
    @MainActor
    func testOptionsWithoutZeroDoNotMakeAGPUTheDefault() {
        XCTAssertEqual(PortalSettingsTab.defaultGPUs(saved: 0, offer: staging), 0)
    }

    @MainActor
    func testASavedDefaultOfSeveralGPUsIsOne() {
        XCTAssertEqual(PortalSettingsTab.defaultGPUs(saved: 4, offer: staging), 1)
    }

    @MainActor
    func testNoOfferMakesItNone() {
        XCTAssertEqual(PortalSettingsTab.defaultGPUs(saved: 1, offer: GPUOffer.none), 0)
    }

    @MainActor
    func testBeforeTheContextItIsAsSaved() {
        XCTAssertEqual(PortalSettingsTab.defaultGPUs(saved: 1, offer: nil), 1)
    }
}
