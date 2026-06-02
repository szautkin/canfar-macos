// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Ticket 059: the `isSelectedSessionTypeDefault` / `isSelectedResourcesDefault`
/// flags are cached stored properties recomputed eagerly at each change point
/// (input `didSet`, default toggles, init) rather than re-reading settings on
/// every view evaluation. These tests pin that the cached values equal the
/// previously-computed results across representative states and that they are
/// invalidated/recomputed after input changes and default toggles.
@MainActor
final class SessionLaunchDefaultFlagsTests: XCTestCase {

    private struct StubLauncher: SessionLaunching {
        func launchSession(_ params: SessionLaunchParams) async throws -> String? { nil }
    }

    private var settingsService: PortalSettingsService!
    private let username = "tester"

    override func setUp() {
        super.setUp()
        settingsService = PortalSettingsService(
            fileName: "test_launch_default_flags_\(UUID().uuidString).json"
        )
    }

    override func tearDown() {
        settingsService.clearAll()
        settingsService = nil
        super.tearDown()
    }

    private func makeModel(username: String? = nil) -> SessionLaunchModel {
        SessionLaunchModel(
            sessionService: StubLauncher(),
            imageService: ImageService(network: NetworkClient(session: .shared)),
            recentLaunchStore: RecentLaunchStore(),
            settingsService: settingsService,
            username: username ?? self.username
        )
    }

    // MARK: - Resources flag across states

    func testFlexibleResourceTypeMatchesSavedDefault() {
        settingsService.setDefaultResources(resourceType: "flexible", cores: nil, ram: nil, gpus: nil, for: username)
        let model = makeModel()
        model.resourceType = "flexible"
        XCTAssertTrue(model.isSelectedResourcesDefault)
    }

    func testFixedMatchingResourcesIsDefault() {
        settingsService.setDefaultResources(resourceType: "fixed", cores: 4, ram: 16, gpus: 1, for: username)
        let model = makeModel()
        model.resourceType = "fixed"
        model.cores = 4
        model.ram = 16
        model.gpus = 1
        XCTAssertTrue(model.isSelectedResourcesDefault)
    }

    func testFixedNonMatchingResourcesNotDefault() {
        settingsService.setDefaultResources(resourceType: "fixed", cores: 4, ram: 16, gpus: 1, for: username)
        let model = makeModel()
        model.resourceType = "fixed"
        model.cores = 8 // differs from saved 4
        model.ram = 16
        model.gpus = 1
        XCTAssertFalse(model.isSelectedResourcesDefault)
    }

    func testEmptyUsernameNeverDefault() {
        settingsService.setDefaultResources(resourceType: "flexible", cores: nil, ram: nil, gpus: nil, for: "")
        let model = makeModel(username: "")
        model.resourceType = "flexible"
        XCTAssertFalse(model.isSelectedResourcesDefault)
        XCTAssertFalse(model.isSelectedSessionTypeDefault)
    }

    func testNoSavedSettingsNotDefault() {
        // settingsService has nothing saved for this user.
        let model = makeModel()
        XCTAssertFalse(model.isSelectedResourcesDefault)
        XCTAssertFalse(model.isSelectedSessionTypeDefault)
    }

    // MARK: - Session-type flag + invalidation via input didSet

    func testSessionTypeDefaultMatchesAndInvalidatesOnChange() {
        settingsService.setDefaultSessionType("desktop", for: username)
        let model = makeModel()
        model.selectedType = "desktop"
        XCTAssertTrue(model.isSelectedSessionTypeDefault, "matches saved default session type")

        model.selectedType = "notebook"
        XCTAssertFalse(model.isSelectedSessionTypeDefault, "flag recomputed when selectedType changes")
    }

    func testChangingCoresInvalidatesResourcesFlag() {
        settingsService.setDefaultResources(resourceType: "fixed", cores: 4, ram: 16, gpus: 1, for: username)
        let model = makeModel()
        model.resourceType = "fixed"
        model.cores = 4
        model.ram = 16
        model.gpus = 1
        XCTAssertTrue(model.isSelectedResourcesDefault)

        model.cores = 8 // diverge from saved default
        XCTAssertFalse(model.isSelectedResourcesDefault, "flag recomputed when cores changes")
    }

    // MARK: - Invalidation after default toggles

    func testToggleDefaultResourcesRecomputesFlag() {
        let model = makeModel()
        model.resourceType = "fixed"
        model.cores = 6
        model.ram = 12
        model.gpus = 0
        XCTAssertFalse(model.isSelectedResourcesDefault, "nothing saved yet")

        model.toggleDefaultResources() // saves current selection as default
        XCTAssertTrue(model.isSelectedResourcesDefault, "flag recomputed true after saving default")

        model.toggleDefaultResources() // clears the saved default
        XCTAssertFalse(model.isSelectedResourcesDefault, "flag recomputed false after clearing default")
    }

    func testToggleDefaultSessionTypeRecomputesFlag() {
        let model = makeModel()
        model.selectedType = "carta"
        XCTAssertFalse(model.isSelectedSessionTypeDefault, "nothing saved yet")

        model.toggleDefaultSessionType() // saves "carta" as default
        XCTAssertTrue(model.isSelectedSessionTypeDefault, "flag recomputed true after saving default")

        model.toggleDefaultSessionType() // clears it
        XCTAssertFalse(model.isSelectedSessionTypeDefault, "flag recomputed false after clearing default")
    }
}
