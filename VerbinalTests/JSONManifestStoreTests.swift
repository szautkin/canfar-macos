// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class JSONManifestStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDiscoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> JSONManifestStore {
        JSONManifestStore(directory: tempDir)
    }

    private func manifest(
        id: String,
        osFamily: String = "ubuntu",
        osVersion: String = "22.04",
        dpkg: [String] = [],
        python: [String] = []
    ) -> ImageManifest {
        ImageManifest(
            schemaVersion: 1,
            imageID: id,
            contentHash: "sha256:test",
            capturedAt: Date(),
            osFamily: osFamily,
            osVersion: osVersion,
            kernel: "Linux test",
            dpkgPackages: dpkg.map { .init(name: $0, version: "1.0") },
            pythonPackages: python.map { .init(name: $0, version: "1.0", source: "pip", env: "base") }
        )
    }

    // MARK: - Round-trip

    func testWriteThenReadRoundTrip() async throws {
        let store = makeStore()
        let m = manifest(id: "images.canfar.net/skaha/astroml:24.07",
                         dpkg: ["libc6"],
                         python: ["astropy", "numpy"])
        try await store.setManifest(m)

        let loaded = await store.outcome(for: "images.canfar.net/skaha/astroml:24.07")
        guard case .success(let got) = loaded else {
            return XCTFail("expected .success, got \(String(describing: loaded))")
        }
        XCTAssertEqual(got.imageID, m.imageID)
        XCTAssertEqual(got.dpkgPackages.map(\.name), ["libc6"])
        XCTAssertEqual(Set(got.pythonPackages.map(\.name)), ["astropy", "numpy"])
    }

    func testFailureOutcomeRoundTrips() async throws {
        let store = makeStore()
        let when = Date()
        try await store.setFailure(
            imageID: "images.canfar.net/skaha/broken:1",
            category: .jobSubmitFailed,
            message: "Skaha 400: unknown image",
            attemptedAt: when
        )
        let loaded = await store.outcome(for: "images.canfar.net/skaha/broken:1")
        guard case .failure(let id, let cat, let msg, let date) = loaded else {
            return XCTFail("expected .failure, got \(String(describing: loaded))")
        }
        XCTAssertEqual(id, "images.canfar.net/skaha/broken:1")
        XCTAssertEqual(cat, .jobSubmitFailed)
        XCTAssertEqual(msg, "Skaha 400: unknown image")
        // ISO-8601 second precision drops sub-second; compare to second
        XCTAssertEqual(Int(date.timeIntervalSince1970), Int(when.timeIntervalSince1970))
    }

    // MARK: - Hydration

    func testHydrationReadsAllFilesAfterRelaunch() async throws {
        let storeA = makeStore()
        try await storeA.setManifest(manifest(id: "test:1", python: ["astropy"]))
        try await storeA.setManifest(manifest(id: "test:2", python: ["numpy"]))
        try await storeA.setFailure(imageID: "test:3", category: .unknown,
                                    message: "x", attemptedAt: Date())

        // Fresh store on the same directory: must see all three.
        let storeB = JSONManifestStore(directory: tempDir)
        let known = await storeB.knownImages()
        XCTAssertEqual(Set(known), Set(["test:1", "test:2", "test:3"]))

        let outcome1 = await storeB.outcome(for: "test:1")
        XCTAssertNotNil(outcome1)
        XCTAssertTrue(outcome1?.isSuccess ?? false)

        let outcome3 = await storeB.outcome(for: "test:3")
        guard case .failure(let id, let cat, _, _) = outcome3 else {
            return XCTFail("expected .failure for test:3")
        }
        XCTAssertEqual(id, "test:3")
        XCTAssertEqual(cat, .unknown)
    }

    // MARK: - Search

    func testSearchEmptyQueryReturnsAllSuccessfulImages() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "a:1", python: ["astropy"]))
        try await store.setManifest(manifest(id: "b:1", python: ["scipy"]))
        try await store.setFailure(imageID: "c:1", category: .jobTimedOut,
                                   message: "x", attemptedAt: Date())

        let results = await store.search(PackageQuery())
        // Failure entries are NOT in search results — they have no manifest.
        XCTAssertEqual(results, ["a:1", "b:1"])
    }

    func testSearchIntersectsAcrossPackages() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "astroml:24",
                                              python: ["astropy", "numpy", "scipy"]))
        try await store.setManifest(manifest(id: "minimal:1",
                                              python: ["numpy"]))
        try await store.setManifest(manifest(id: "casa:6",
                                              python: ["astropy", "numpy"]))

        var query = PackageQuery()
        query.python = ["astropy", "numpy"]
        let results = await store.search(query)
        XCTAssertEqual(results, ["astroml:24", "casa:6"])
    }

    func testSearchByOSFamily() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "u:1", osFamily: "ubuntu", osVersion: "22.04"))
        try await store.setManifest(manifest(id: "a:1", osFamily: "almalinux", osVersion: "9"))
        try await store.setManifest(manifest(id: "u:2", osFamily: "ubuntu", osVersion: "20.04"))

        var q = PackageQuery()
        q.osFamilies = ["ubuntu"]
        let r = await store.search(q)
        XCTAssertEqual(r, ["u:1", "u:2"])
    }

    func testSearchCombinesOSAndPackage() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "u-astro:1", osFamily: "ubuntu",
                                              python: ["astropy"]))
        try await store.setManifest(manifest(id: "a-astro:1", osFamily: "almalinux",
                                              python: ["astropy"]))
        try await store.setManifest(manifest(id: "u-bare:1", osFamily: "ubuntu"))

        var q = PackageQuery()
        q.osFamilies = ["ubuntu"]
        q.python = ["astropy"]
        let r = await store.search(q)
        XCTAssertEqual(r, ["u-astro:1"])
    }

    func testSearchNoMatchReturnsEmpty() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "u:1", python: ["numpy"]))

        var q = PackageQuery()
        q.python = ["nonexistent"]
        let r = await store.search(q)
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - All packages aggregation

    func testAllPackagesAggregatesAcrossSuccessfulManifests() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "u:1", osFamily: "ubuntu", osVersion: "22.04",
                                              dpkg: ["libc6", "ssh"], python: ["astropy"]))
        try await store.setManifest(manifest(id: "u:2", osFamily: "ubuntu", osVersion: "20.04",
                                              dpkg: ["libc6"], python: ["numpy"]))
        try await store.setManifest(manifest(id: "a:1", osFamily: "almalinux", osVersion: "9",
                                              dpkg: [], python: ["astropy"]))
        try await store.setFailure(imageID: "f:1", category: .unknown,
                                   message: "x", attemptedAt: Date())

        let all = await store.allPackages()
        XCTAssertEqual(all.osFamilies, ["ubuntu", "almalinux"])
        XCTAssertEqual(all.osVersionsByFamily["ubuntu"], ["22.04", "20.04"])
        XCTAssertEqual(all.osVersionsByFamily["almalinux"], ["9"])
        XCTAssertEqual(all.dpkg, ["libc6", "ssh"])
        XCTAssertEqual(all.python, ["astropy", "numpy"])
        // Failure entries don't contribute to package union.
    }

    // MARK: - Invalidate / clear

    func testInvalidateRemovesSingleEntryFromMemoryAndDisk() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "keep:1"))
        try await store.setManifest(manifest(id: "drop:1"))

        try await store.invalidate(imageID: "drop:1")

        let dropOutcome = await store.outcome(for: "drop:1")
        let keepOutcome = await store.outcome(for: "keep:1")
        XCTAssertNil(dropOutcome)
        XCTAssertNotNil(keepOutcome)

        // Verify on disk too.
        let safe = ImageManifest.sanitize(imageID: "drop:1")
        let url = tempDir.appendingPathComponent(safe + ".json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearWipesEverything() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "a:1"))
        try await store.setManifest(manifest(id: "b:1"))
        try await store.setFailure(imageID: "c:1", category: .unknown,
                                   message: "x", attemptedAt: Date())

        try await store.clear()
        let zeroCount = await store.count()
        XCTAssertEqual(zeroCount, 0)

        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let jsons = contents.filter { $0.pathExtension == "json" }
        XCTAssertTrue(jsons.isEmpty)
    }

    // MARK: - Concurrent writers

    func testConcurrentSetManifestDoesNotCorruptCache() async throws {
        let store = makeStore()
        let count = 50
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    try? await store.setManifest(self.manifest(id: "concurrent:\(i)",
                                                                python: ["pkg-\(i)"]))
                }
            }
        }
        let storeCount = await store.count()
        XCTAssertEqual(storeCount, count)

        // Re-hydrate from disk — the on-disk state must match.
        let fresh = JSONManifestStore(directory: tempDir)
        let freshCount = await fresh.count()
        XCTAssertEqual(freshCount, count)

        // Pick a random one and verify the manifest came through clean.
        let outcome = await fresh.outcome(for: "concurrent:25")
        guard case .success(let m) = outcome else {
            return XCTFail("expected success for concurrent:25, got \(String(describing: outcome))")
        }
        XCTAssertEqual(m.pythonPackages.first?.name, "pkg-25")
    }

    // MARK: - File path sanitization

    func testFilenameSanitizationHandlesRegistryColon() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "images.canfar.net/skaha/astroml:24.07"))

        // Verify file name on disk uses underscores, not slashes/colons.
        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let names = contents.map(\.lastPathComponent)
        XCTAssertTrue(names.contains("images.canfar.net_skaha_astroml_24.07.json"),
                      "got: \(names)")
    }

    // MARK: - Bootstrap is idempotent

    func testBootstrapTwiceIsNoOp() async throws {
        let store = makeStore()
        try await store.setManifest(manifest(id: "x:1"))
        await store.bootstrap()
        await store.bootstrap()
        let oneCount = await store.count()
        XCTAssertEqual(oneCount, 1)
    }
}
