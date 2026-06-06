// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Coverage for the AI Remote Compute settings module — registry host +
/// username + image persistence, the empty-clears-image contract the
/// `run_code` tool depends on, and the resolver/service key agreement.
/// (Secret storage hits the real Keychain, so it's exercised only for
/// the no-secret → nil path, which is what `run_code`'s public-image
/// launch relies on.)
final class AIComputeSettingsServiceTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "test.aicompute.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private let sample = "images.canfar.net/private-test/verbinal-execution:0.0.1"

    @MainActor
    func testDefaultsEmptyAndDisabled() {
        let svc = AIComputeSettingsService(userDefaults: freshDefaults())
        XCTAssertEqual(svc.settings.image, "")
        XCTAssertFalse(svc.settings.isEnabled)
        XCTAssertEqual(svc.settings.registryHost, "images.canfar.net")
        XCTAssertFalse(svc.settings.hasSecret)
        XCTAssertTrue(svc.settings.isAllDefaults)
    }

    @MainActor
    func testSetImagePersistsTrimsAndResolverReadsIt() {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        svc.setImage("  \(sample)  ")
        XCTAssertEqual(svc.settings.image, sample)
        XCTAssertTrue(svc.settings.isEnabled)
        XCTAssertFalse(svc.settings.isAllDefaults)
        // The resolver the run_code tool uses reads the same key.
        XCTAssertEqual(AIComputeImage.resolvedImageID(d), sample)
        XCTAssertTrue(AIComputeImage.isEnabled(d))
        // Survives a reload (= app relaunch) on the same store.
        let reloaded = AIComputeSettingsService(userDefaults: d)
        XCTAssertEqual(reloaded.settings.image, sample)
    }

    @MainActor
    func testEmptyImageClearsOverride() {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        svc.setImage(sample)
        svc.setImage("   ")   // whitespace = clear (no built-in fallback)
        XCTAssertEqual(svc.settings.image, "")
        XCTAssertFalse(svc.settings.isEnabled)
        XCTAssertEqual(AIComputeImage.resolvedImageID(d), "")
    }

    @MainActor
    func testRegistryHostAndUsernamePersist() {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        svc.setRegistryHost("harbor.example.org")
        svc.setUsername("alice")
        XCTAssertEqual(svc.settings.registryHost, "harbor.example.org")
        XCTAssertEqual(svc.settings.username, "alice")
        XCTAssertFalse(svc.settings.isAllDefaults)
        let reloaded = AIComputeSettingsService(userDefaults: d)
        XCTAssertEqual(reloaded.settings.registryHost, "harbor.example.org")
        XCTAssertEqual(reloaded.settings.username, "alice")
    }

    @MainActor
    func testEmptyHostRevertsToCanfarDefault() {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        svc.setRegistryHost("harbor.example.org")
        svc.setRegistryHost("   ")
        XCTAssertEqual(svc.settings.registryHost, "images.canfar.net")
    }

    @MainActor
    func testRegistryCredentialsNilWithoutSecret() {
        let svc = AIComputeSettingsService(userDefaults: freshDefaults())
        svc.setUsername("alice")
        XCTAssertNil(svc.registryCredentials(),
                     "no stored secret → run_code launches the image without registry auth (public-image path)")
    }

    @MainActor
    func testResetClearsEverything() throws {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        svc.setImage(sample)
        svc.setRegistryHost("x.org")
        svc.setUsername("alice")
        try svc.resetToDefaults()
        XCTAssertEqual(svc.settings.image, "")
        XCTAssertEqual(svc.settings.registryHost, "images.canfar.net")
        XCTAssertEqual(svc.settings.username, "")
        XCTAssertEqual(AIComputeImage.resolvedImageID(d), "")
    }

    func testResolverKeyMatchesServiceKey() {
        XCTAssertEqual(AIComputeImage.imageDefaultsKey, "com.codebg.Verbinal.aiCompute.image")
        XCTAssertEqual(AIComputeImage.builtinImageID, "")
        XCTAssertEqual(AIComputeImage.coresDefaultsKey, "com.codebg.Verbinal.aiCompute.cores")
        XCTAssertEqual(AIComputeImage.ramDefaultsKey, "com.codebg.Verbinal.aiCompute.ram")
    }

    // MARK: - Resources (cores / ram default size)

    @MainActor
    func testDefaultResourcesAreSmallest() {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        XCTAssertEqual(svc.settings.cores, 1)
        XCTAssertEqual(svc.settings.ram, 1)
        // The resolver the MCP tools use reads the same store, defaulting (1,1).
        let r = AIComputeImage.resolvedResources(d)
        XCTAssertEqual(r.cores, 1)
        XCTAssertEqual(r.ram, 1)
    }

    @MainActor
    func testSetResourcesPersistAndResolverReadsThem() {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        svc.setCores(4)
        svc.setRam(16)
        XCTAssertEqual(svc.settings.cores, 4)
        XCTAssertEqual(svc.settings.ram, 16)
        XCTAssertFalse(svc.settings.isAllDefaults)
        let r = AIComputeImage.resolvedResources(d)
        XCTAssertEqual(r.cores, 4)
        XCTAssertEqual(r.ram, 16)
        // Survives a reload (= app relaunch) on the same store.
        let reloaded = AIComputeSettingsService(userDefaults: d)
        XCTAssertEqual(reloaded.settings.cores, 4)
        XCTAssertEqual(reloaded.settings.ram, 16)
    }

    @MainActor
    func testSetResourcesClampToOne() {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        svc.setCores(0)
        svc.setRam(-5)
        XCTAssertEqual(svc.settings.cores, 1, "0 cores clamps to the 1-core floor")
        XCTAssertEqual(svc.settings.ram, 1)
    }

    @MainActor
    func testResetClearsResources() throws {
        let d = freshDefaults()
        let svc = AIComputeSettingsService(userDefaults: d)
        svc.setCores(8)
        svc.setRam(32)
        try svc.resetToDefaults()
        XCTAssertEqual(svc.settings.cores, 1)
        XCTAssertEqual(svc.settings.ram, 1)
        let r = AIComputeImage.resolvedResources(d)
        XCTAssertEqual(r.cores, 1)
        XCTAssertEqual(r.ram, 1)
    }
}
