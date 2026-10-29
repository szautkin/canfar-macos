// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Persistence + relaunch-flag behavior of the endpoint-overrides store.
/// Uses an isolated `UserDefaults` suite so runs never touch real prefs.
@MainActor
final class EndpointSettingsServiceTests: XCTestCase {

    private static let suiteName = "test-endpoints-settings"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func testOverridesRoundTripThroughPersistence() {
        let service = EndpointSettingsService(userDefaults: defaults)
        service.setOverride("https://my.host/skaha", for: .skahaBaseURL)
        service.setOverride("https://my.host/reg", for: .registryBaseURL)

        let reloaded = EndpointSettingsService(userDefaults: defaults)
        XCTAssertEqual(reloaded.overrides[.skahaBaseURL], "https://my.host/skaha")
        XCTAssertEqual(reloaded.overrides[.registryBaseURL], "https://my.host/reg")
        XCTAssertNil(reloaded.overrides[.loginBaseURL])
    }

    /// Plan 53 C5: a change is told at once, so it applies live; a load is not a change.
    func testAChangeIsToldAtOnceALoadIsNot() {
        let service = EndpointSettingsService(userDefaults: defaults)
        var told = 0
        service.onChange = { told += 1 }
        service.setOverride("https://my.host/skaha", for: .skahaBaseURL)
        XCTAssertEqual(told, 1)

        let reloaded = EndpointSettingsService(userDefaults: defaults)
        var reloadTold = 0
        reloaded.onChange = { reloadTold += 1 }
        XCTAssertEqual(reloaded.overrides[.skahaBaseURL], "https://my.host/skaha")
        XCTAssertEqual(reloadTold, 0, "Loading persisted overrides is not a change")
    }

    func testANoOpWriteTellsNothing() {
        let service = EndpointSettingsService(userDefaults: defaults)
        service.setOverride("https://my.host/skaha", for: .skahaBaseURL)

        let reloaded = EndpointSettingsService(userDefaults: defaults)
        var told = 0
        reloaded.onChange = { told += 1 }
        reloaded.setOverride("https://my.host/skaha/", for: .skahaBaseURL)
        XCTAssertEqual(told, 0, "Same normalized value changes nothing")
    }

    func testClearOverrideRemovesEntry() {
        let service = EndpointSettingsService(userDefaults: defaults)
        service.setOverride("https://my.host/skaha", for: .skahaBaseURL)
        service.clearOverride(for: .skahaBaseURL)
        XCTAssertNil(service.overrides[.skahaBaseURL])

        let reloaded = EndpointSettingsService(userDefaults: defaults)
        XCTAssertNil(reloaded.overrides[.skahaBaseURL])
    }

    func testResetToDefaultsDropsEverything() {
        let service = EndpointSettingsService(userDefaults: defaults)
        service.setOverride("https://a.example.org", for: .archiveBaseURL)
        service.setOverride("https://b.example.org", for: .externalBaseURL)

        service.resetToDefaults()
        XCTAssertTrue(service.overrides.isEmpty)

        let reloaded = EndpointSettingsService(userDefaults: defaults)
        XCTAssertTrue(reloaded.overrides.isEmpty)
    }

    func testResetOnPristineStoreIsNoOp() {
        let service = EndpointSettingsService(userDefaults: defaults)
        var told = 0
        service.onChange = { told += 1 }
        service.resetToDefaults()
        XCTAssertEqual(told, 0)
    }
}
