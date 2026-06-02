// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for the long-lived in-flight count subscription on
/// `ImageDiscoveryModel` (the magnifier-badge feed).
///
/// 2026 hardening pass (ticket 022): the subscription Task is now an
/// immutable `let` (no `nonisolated(unsafe) var`) and runs at
/// `.utility` priority. These tests pin the observable behaviour the
/// hardening must preserve:
///   * `inFlightProbeCount` converges to the coordinator's final
///     in-flight count after a sequence of count changes.
///   * Deallocating the model unregisters the coordinator-side
///     continuation (subscriber count returns to zero) via the
///     stream's `.onTermination`.
///   * The subscription captures `self` weakly — dropping the only
///     strong reference releases the model even while the stream is
///     still open.
@MainActor
final class ImageDiscoveryModelInFlightSubscriptionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelInFlightTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Build a coordinator whose probes sit Pending for
    /// `completeAfterPolls` polls (so callers can observe the
    /// intermediate in-flight count) and that writes a manifest at
    /// the expected VOSpace path on launch (so probes eventually
    /// complete and the count drains back to zero).
    private func makeCoord(
        completeAfterPolls: Int
    ) -> (ImageDiscoveryCoordinator,
          ImageDiscoveryCoordinatorTests.MockHeadless,
          ImageDiscoveryCoordinatorTests.MockVOSpace) {
        let store = JSONManifestStore(directory: tempDir)
        let headless = ImageDiscoveryCoordinatorTests.MockHeadless()
        headless.completeAfterPolls = completeAfterPolls
        let vospace = ImageDiscoveryCoordinatorTests.MockVOSpace()
        // Mirror the realistic probe: each launch seeds the VOSpace
        // fixture with a manifest at the launched image's path so the
        // post-poll fetch succeeds and the in-flight entry clears.
        headless.onLaunchSimulate = { [weak vospace] params in
            let safe = ImageManifest.sanitize(imageID: params.image)
            let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
            vospace?.fileContents[path] = Self.manifestJSON(imageID: params.image)
        }
        let coord = ImageDiscoveryCoordinator(
            store: store,
            headless: headless,
            vospace: vospace,
            username: "testuser",
            probeJobTimeout: 5.0,
            pollInterval: 0.01,
            maxConcurrentProbes: 5,
            imageTypesLookup: { _ in ["headless"] }
        )
        return (coord, headless, vospace)
    }

    private static nonisolated func manifestJSON(imageID: String) -> Data {
        let body: [String: Any] = [
            "schemaVersion": 1,
            "imageID": imageID,
            "contentHash": "sha256:test",
            "capturedAt": "2026-05-19T12:00:00Z",
            "osFamily": "ubuntu",
            "osVersion": "22.04",
            "kernel": "Linux",
            "dpkgPackages": [],
            "rpmPackages": [],
            "apkPackages": [],
            "pythonPackages": [],
            "rPackages": [],
            "condaEnvs": []
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Poll `predicate` every 20ms until true or `timeout` elapses;
    /// fails the test on timeout. Used to bridge actor-isolated and
    /// async state to assertions without expectation plumbing.
    private func poll(
        timeout: TimeInterval,
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("poll exceeded \(timeout)s")
    }

    // MARK: - Convergence

    /// The model subscribes in init and `inFlightProbeCount` must
    /// converge to the coordinator's final in-flight count after a
    /// sequence of count changes (several probes launch, all
    /// complete, count returns to 0).
    func testInFlightProbeCountConvergesToFinalValue() async throws {
        // Probes stay Pending for several polls so the count rises
        // above zero before draining.
        let (coord, _, _) = makeCoord(completeAfterPolls: 4)
        let model = ImageDiscoveryModel(coordinator: coord)

        // Initial subscribe yields 0.
        try await poll(timeout: 2.0) { model.inFlightProbeCount == 0 }

        // Launch a batch of probes concurrently. Each increments the
        // coordinator's in-flight count; the model's subscription
        // mirrors the changes onto `inFlightProbeCount`. The probes
        // sit Pending for several polls (completeAfterPolls: 4) so
        // the count genuinely rises above zero before draining.
        let ids = (1...3).map { "test:img\($0)" }
        let batch = Task {
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { _ = try? await coord.discover(id) }
                }
            }
        }

        // Let every probe finish.
        _ = await batch.value

        // The final coordinator count is 0; the model must converge
        // to exactly that value.
        try await poll(timeout: 3.0) {
            let coordCount = await coord.inFlightCount()
            return coordCount == 0 && model.inFlightProbeCount == 0
        }
        let finalModelCount = model.inFlightProbeCount
        let finalCoordCount = await coord.inFlightCount()
        XCTAssertEqual(finalModelCount, finalCoordCount,
                       "model count must converge to the coordinator's final in-flight count")
        XCTAssertEqual(finalModelCount, 0)
    }

    // MARK: - Continuation cleanup on dealloc

    /// Dropping the only strong reference to the model must end its
    /// subscription Task (weak-self loop returns), whose stream
    /// termination fires `.onTermination` and unregisters the
    /// coordinator-side continuation. The coordinator's subscriber
    /// count must return to zero.
    func testDeallocUnregistersCoordinatorContinuation() async throws {
        let (coord, _, _) = makeCoord(completeAfterPolls: 0)

        var model: ImageDiscoveryModel? = ImageDiscoveryModel(coordinator: coord)
        // Touch it so the optimiser can't drop the allocation early.
        _ = model?.inFlightProbeCount

        // The subscription should register exactly one continuation.
        try await poll(timeout: 2.0) {
            await coord.inFlightSubscriberCount() == 1
        }

        // Drop the only strong reference. deinit cancels the Task;
        // the stream finishes and `.onTermination` unregisters the
        // coordinator-side continuation.
        model = nil

        try await poll(timeout: 3.0) {
            await coord.inFlightSubscriberCount() == 0
        }
        let subscribers = await coord.inFlightSubscriberCount()
        XCTAssertEqual(subscribers, 0,
                       "coordinator continuation must be unregistered after the model deallocates")
    }

    // MARK: - No retain cycle

    /// The subscription captures `self` weakly, so dropping the only
    /// strong reference releases the model even while the stream is
    /// still open (no probe has finished it). A `weak` observer must
    /// go nil shortly after the strong reference is cleared.
    func testSubscriptionDoesNotRetainModel() async throws {
        // `completeAfterPolls: 9999` keeps the stream alive — no
        // launch happens here, but this guarantees that even if one
        // did the stream wouldn't naturally finish during the test.
        let (coord, _, _) = makeCoord(completeAfterPolls: 9999)

        weak var weakModel: ImageDiscoveryModel?
        var strongModel: ImageDiscoveryModel? = ImageDiscoveryModel(coordinator: coord)
        weakModel = strongModel

        // Let the subscription register and take its initial value
        // so the stream is genuinely open while we drop the ref.
        try await poll(timeout: 2.0) {
            await coord.inFlightSubscriberCount() == 1
        }
        XCTAssertNotNil(weakModel, "model alive while strongly held")

        // Drop the only strong reference while the stream is open.
        strongModel = nil

        // Weak-self capture means the model is not retained by the
        // subscription Task — it must be released.
        try await poll(timeout: 3.0) { weakModel == nil }
        XCTAssertNil(weakModel,
                     "subscription must not retain the model; it should release once the strong ref is dropped")
    }
}
