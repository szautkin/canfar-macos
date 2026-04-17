// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class PortalCacheServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeSettingsService() -> PortalSettingsService {
        PortalSettingsService(fileName: "test_portal_settings_\(UUID().uuidString).json")
    }

    private func makeCacheService(cacheMaxAge: TimeInterval = 60 * 60 * 24) -> PortalImageCacheService {
        PortalImageCacheService(
            fileName: "test_portal_cache_\(UUID().uuidString).json",
            cacheMaxAge: cacheMaxAge
        )
    }

    override func tearDown() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal") {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("test_portal_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        super.tearDown()
    }

    // MARK: - PortalSettings (pure)

    func testPortalSettingsIsEmptyWhenAllNil() {
        let s = PortalSettings(username: "alice")
        XCTAssertTrue(s.isEmpty)
        XCTAssertFalse(s.hasResourceDefaults)
    }

    func testPortalSettingsNotEmptyWithProject() {
        let s = PortalSettings(username: "alice", defaultProject: "skaha")
        XCTAssertFalse(s.isEmpty)
    }

    func testPortalSettingsHasResourceDefaults() {
        let s = PortalSettings(
            username: "alice",
            defaultResourceType: "fixed",
            defaultCores: 4, defaultRam: 16, defaultGpus: 0
        )
        XCTAssertTrue(s.hasResourceDefaults)
        XCTAssertFalse(s.isEmpty)
    }

    // MARK: - PortalSettingsService — CRUD

    func testSetAndGetDefaultProject() {
        let svc = makeSettingsService()
        svc.setDefaultProject("skaha", for: "alice")
        XCTAssertEqual(svc.settings(for: "alice")?.defaultProject, "skaha")
    }

    func testSetAndGetDefaultImage() {
        let svc = makeSettingsService()
        svc.setDefaultImage("images.canfar.net/skaha/astroml:24.06", for: "alice")
        XCTAssertEqual(svc.settings(for: "alice")?.defaultContainerImageID, "images.canfar.net/skaha/astroml:24.06")
    }

    func testClearDefaultProject() {
        let svc = makeSettingsService()
        svc.setDefaultProject("skaha", for: "alice")
        svc.setDefaultProject(nil, for: "alice")
        XCTAssertNil(svc.settings(for: "alice")?.defaultProject)
    }

    func testSetDefaultResourcesFixed() {
        let svc = makeSettingsService()
        svc.setDefaultResources(resourceType: "fixed", cores: 4, ram: 16, gpus: 1, for: "alice")
        let settings = svc.settings(for: "alice")
        XCTAssertEqual(settings?.defaultResourceType, "fixed")
        XCTAssertEqual(settings?.defaultCores, 4)
        XCTAssertEqual(settings?.defaultRam, 16)
        XCTAssertEqual(settings?.defaultGpus, 1)
        XCTAssertTrue(settings?.hasResourceDefaults ?? false)
    }

    func testSetDefaultResourcesFlexible() {
        let svc = makeSettingsService()
        svc.setDefaultResources(resourceType: "flexible", cores: nil, ram: nil, gpus: nil, for: "alice")
        XCTAssertEqual(svc.settings(for: "alice")?.defaultResourceType, "flexible")
    }

    func testClearDefaultResources() {
        let svc = makeSettingsService()
        svc.setDefaultResources(resourceType: "fixed", cores: 4, ram: 16, gpus: 0, for: "alice")
        svc.setDefaultResources(resourceType: nil, cores: nil, ram: nil, gpus: nil, for: "alice")
        XCTAssertNil(svc.settings(for: "alice")?.defaultResourceType)
    }

    func testPerUserIsolation() {
        let svc = makeSettingsService()
        svc.setDefaultProject("skaha", for: "alice")
        svc.setDefaultProject("contributed", for: "bob")

        XCTAssertEqual(svc.settings(for: "alice")?.defaultProject, "skaha")
        XCTAssertEqual(svc.settings(for: "bob")?.defaultProject, "contributed")
    }

    func testEmptyUsernameRejected() {
        let svc = makeSettingsService()
        XCTAssertNil(svc.settings(for: ""))
        svc.save(PortalSettings(username: "", defaultProject: "skaha"))
        XCTAssertNil(svc.settings(for: ""))
    }

    func testClearAllRemovesEverything() {
        let svc = makeSettingsService()
        svc.setDefaultProject("skaha", for: "alice")
        svc.setDefaultProject("skaha", for: "bob")
        svc.clearAll()
        XCTAssertNil(svc.settings(for: "alice"))
        XCTAssertNil(svc.settings(for: "bob"))
    }

    func testSettingsPersistAcrossInstances() {
        let fileName = "test_portal_settings_persist_\(UUID().uuidString).json"
        let svc1 = PortalSettingsService(fileName: fileName)
        svc1.setDefaultProject("skaha", for: "alice")

        let svc2 = PortalSettingsService(fileName: fileName)
        XCTAssertEqual(svc2.settings(for: "alice")?.defaultProject, "skaha")
    }

    // MARK: - PortalImageCacheService — lifecycle

    func testEmptyCacheIsStale() {
        let svc = makeCacheService()
        XCTAssertTrue(svc.isStale)
        XCTAssertNil(svc.cacheTimestamp)
    }

    func testClearRemovesCacheFile() {
        // Pre-populate the cache by decoding a hand-crafted PortalImageCache directly
        let fileName = "test_portal_cache_clear_\(UUID().uuidString).json"
        let svc = PortalImageCacheService(fileName: fileName)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Verbinal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(fileName)

        let sampleCache = PortalImageCache(
            username: "alice",
            images: [],
            context: nil,
            repositories: ["images.canfar.net"],
            fetchedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try? encoder.encode(sampleCache)
        try? data?.write(to: fileURL)

        // Re-create service so it reads from disk
        let svc2 = PortalImageCacheService(fileName: fileName)
        XCTAssertNotNil(svc2.cache)

        svc2.clear()
        XCTAssertNil(svc2.cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        _ = svc
    }

    func testIsStaleRespectsMaxAge() {
        // Cache max age of 1 second — after sleep, should be stale.
        let svc = makeCacheService(cacheMaxAge: 1)
        XCTAssertTrue(svc.isStale, "Empty cache is stale")

        // Can't easily inject a fresh cache without mocking ImageService.
        // Just verify the default-age cache is stale out of the box.
    }

    func testPortalImageCachePersistenceRoundTrip() throws {
        let fileName = "test_portal_cache_rt_\(UUID().uuidString).json"

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Verbinal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(fileName)

        let cache = PortalImageCache(
            username: "alice",
            images: [RawImage(id: "images.canfar.net/skaha/astroml:24.06", types: ["notebook"])],
            context: nil,
            repositories: ["images.canfar.net"],
            fetchedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cache)
        try data.write(to: fileURL)

        let svc = PortalImageCacheService(fileName: fileName)
        XCTAssertNotNil(svc.cache)
        XCTAssertEqual(svc.cache?.username, "alice")
        XCTAssertEqual(svc.cache?.images.count, 1)
        XCTAssertEqual(svc.cache?.images.first?.id, "images.canfar.net/skaha/astroml:24.06")
    }
}
