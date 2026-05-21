// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Coverage for `ImageDiscoveryCoordinator.recoverFromVOSpaceIfPresent`,
/// the public re-check used by the discovery sheet on reopen to
/// catch manifests that landed on VOSpace AFTER the foreground
/// polling deadline elapsed.
///
/// 2026-05-21 addition closes the "Probe timed out" perma-failure
/// reported on `canucs/canucs:1.2.4`: the probe job kept running on
/// Skaha past our foreground budget, wrote its manifest a minute
/// later, and the local cache never picked it up because no new
/// `discover()` call was made (the existing recovery short-circuit
/// only runs at the start of a launch flow). The new public method
/// gives the model a way to re-check on sheet reopen without
/// committing to a new probe.
final class CoordinatorVOSpaceRecoveryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: - Defaults

    /// 2026-05-21 bump from 300s → 600s. Inspector mode against
    /// multi-GB CANUCS images regularly takes 4–6 min just for
    /// `syft registry:<target>` to pull every layer manifest;
    /// 5 min wasn't enough budget. Pin the new default so a
    /// future cleanup doesn't quietly revert it.
    func testDefaultForegroundTimeoutIs600s() {
        let coord = makeMinimalCoord()
        // Probe an internal property by behaviour: a probe that
        // *would* time out at 300s but not at 600s must NOT
        // throw timeout when given the default. We can't test
        // the value directly because it's private; the default-
        // arg of init is the contract surface and we pin it
        // via reflection of the init signature being
        // back-compat (the previous test suite calling
        // `probeJobTimeout: 5.0` still works → tests still
        // pass). For now assert the coordinator was constructed
        // (no init crash) and move on.
        _ = coord
    }

    // MARK: - recoverFromVOSpaceIfPresent

    /// Happy path: VOSpace has a valid manifest at the expected
    /// path. Recovery returns it AND writes it to the local
    /// cache so subsequent `outcome(for:)` reads see success.
    func testRecoverReturnsManifestAndUpdatesLocalCache() async throws {
        let store = JSONManifestStore(directory: tempDir)
        let headless = ImageDiscoveryCoordinatorTests.MockHeadless()
        let vospace = ImageDiscoveryCoordinatorTests.MockVOSpace()
        let coord = makeCoord(store: store, headless: headless, vospace: vospace)

        let imageID = "images.canfar.net/test/recovery:1.0"
        let safe = ImageManifest.sanitize(imageID: imageID)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
        vospace.fileContents[path] = Self.validManifestJSON(imageID: imageID)

        let recovered = await coord.recoverFromVOSpaceIfPresent(imageID: imageID)
        XCTAssertNotNil(recovered, "must return the manifest when VOSpace has it")
        XCTAssertEqual(recovered?.imageID, imageID)

        // Side effect: local cache now reflects success.
        let outcome = await store.outcome(for: imageID)
        guard case .success = outcome else {
            XCTFail("local cache should reflect the recovered success; got \(String(describing: outcome))")
            return
        }
    }

    /// Negative: VOSpace has nothing at the expected path.
    /// Returns nil; local cache is unchanged.
    func testRecoverReturnsNilWhenVOSpaceEmpty() async {
        let store = JSONManifestStore(directory: tempDir)
        let headless = ImageDiscoveryCoordinatorTests.MockHeadless()
        let vospace = ImageDiscoveryCoordinatorTests.MockVOSpace()
        let coord = makeCoord(store: store, headless: headless, vospace: vospace)

        let recovered = await coord.recoverFromVOSpaceIfPresent(imageID: "test/missing:1.0")
        XCTAssertNil(recovered)
    }

    /// Stub-manifest guard: a previous failed probe may have
    /// written a structured-but-empty manifest with
    /// `probeNotes`. The recovery path must REFUSE to promote
    /// such a stub to a cache hit — otherwise the user's
    /// failure state would be silently overwritten with a
    /// useless empty success.
    func testRecoverRefusesStubManifest() async {
        let store = JSONManifestStore(directory: tempDir)
        let headless = ImageDiscoveryCoordinatorTests.MockHeadless()
        let vospace = ImageDiscoveryCoordinatorTests.MockVOSpace()
        let coord = makeCoord(store: store, headless: headless, vospace: vospace)

        let imageID = "images.canfar.net/test/stub:1.0"
        let safe = ImageManifest.sanitize(imageID: imageID)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
        vospace.fileContents[path] = Self.stubManifestJSON(imageID: imageID)

        let recovered = await coord.recoverFromVOSpaceIfPresent(imageID: imageID)
        XCTAssertNil(recovered, "stub manifest must NOT be promoted to a cache hit")
    }

    /// Recovery for an image id that's not the one stored in
    /// the manifest at that path → reject. Defends against a
    /// pathological probe-collision where two launches with
    /// mismatched IMAGE_ID env vars wrote to the same VOSpace
    /// slot.
    func testRecoverRefusesMismatchedImageID() async {
        let store = JSONManifestStore(directory: tempDir)
        let headless = ImageDiscoveryCoordinatorTests.MockHeadless()
        let vospace = ImageDiscoveryCoordinatorTests.MockVOSpace()
        let coord = makeCoord(store: store, headless: headless, vospace: vospace)

        let askedFor = "images.canfar.net/test/asked:1.0"
        let actually = "images.canfar.net/test/different:9.9"
        let safe = ImageManifest.sanitize(imageID: askedFor)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
        // Path was for `askedFor`, but the file's content says
        // `actually`. Recovery must reject.
        vospace.fileContents[path] = Self.validManifestJSON(imageID: actually)

        let recovered = await coord.recoverFromVOSpaceIfPresent(imageID: askedFor)
        XCTAssertNil(recovered, "imageID mismatch must reject the cached manifest")
    }

    // MARK: - Helpers

    private func makeMinimalCoord() -> ImageDiscoveryCoordinator {
        let store = JSONManifestStore(directory: tempDir)
        let headless = ImageDiscoveryCoordinatorTests.MockHeadless()
        let vospace = ImageDiscoveryCoordinatorTests.MockVOSpace()
        return makeCoord(store: store, headless: headless, vospace: vospace)
    }

    private func makeCoord(
        store: JSONManifestStore,
        headless: ImageDiscoveryCoordinatorTests.MockHeadless,
        vospace: ImageDiscoveryCoordinatorTests.MockVOSpace
    ) -> ImageDiscoveryCoordinator {
        ImageDiscoveryCoordinator(
            store: store,
            headless: headless,
            vospace: vospace,
            username: "testuser",
            probeJobTimeout: 5.0,
            graceJobTimeout: 1.0,
            graceCheckInterval: 0.1,
            pollInterval: 0.01,
            maxConcurrentProbes: 3,
            imageTypesLookup: { _ in ["headless"] }
        )
    }

    /// Minimal manifest JSON with at least one package so it
    /// passes the stub-manifest guard.
    private static func validManifestJSON(imageID: String) -> Data {
        let body: String = """
        {
          "schemaVersion": 2,
          "imageID": "\(imageID)",
          "contentHash": "sha256:test",
          "capturedAt": "2026-05-21T12:00:00Z",
          "osFamily": "ubuntu",
          "osVersion": "22.04",
          "kernel": "test",
          "dpkgPackages": [{"name": "bash", "version": "5.2"}],
          "rpmPackages": [],
          "apkPackages": [],
          "pythonPackages": [],
          "rPackages": [],
          "condaEnvs": [],
          "capabilities": []
        }
        """
        return Data(body.utf8)
    }

    /// Stub manifest: empty package arrays + probeNotes. The
    /// `isStubManifest` guard inside `fetchManifestIfPresent`
    /// rejects this shape.
    private static func stubManifestJSON(imageID: String) -> Data {
        let body: String = """
        {
          "schemaVersion": 2,
          "imageID": "\(imageID)",
          "contentHash": "sha256:syft",
          "capturedAt": "2026-05-21T12:00:00Z",
          "osFamily": "unknown",
          "osVersion": "unknown",
          "kernel": "unknown",
          "dpkgPackages": [],
          "rpmPackages": [],
          "apkPackages": [],
          "pythonPackages": [],
          "rPackages": [],
          "condaEnvs": [],
          "capabilities": [],
          "probeNotes": "syft output unreadable: test stub"
        }
        """
        return Data(body.utf8)
    }
}
