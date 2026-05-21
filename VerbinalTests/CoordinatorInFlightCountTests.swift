// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for `ImageDiscoveryCoordinator.inFlightCount()` /
/// `inFlightImageIDs()` / `inFlightCountChanges()`.
///
/// 2026-05-19 addition closes the "Close button + visible
/// background-job tracking" pair: the Discovery sheet's footer
/// "Close" now keeps probes running, and `LaunchFormView`'s
/// magnifier icon shows a numeric badge bound to this stream so the
/// user retains awareness of in-flight work after dismissing the
/// sheet. Pinning the stream + getter contract here so future
/// changes can't silently regress the badge to "always 0".
final class CoordinatorInFlightCountTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InFlightTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeCoord(
        completeAfterPolls: Int = 0
    ) -> (ImageDiscoveryCoordinator,
          ImageDiscoveryCoordinatorTests.MockHeadless,
          ImageDiscoveryCoordinatorTests.MockVOSpace) {
        let store = JSONManifestStore(directory: tempDir)
        let headless = ImageDiscoveryCoordinatorTests.MockHeadless()
        headless.completeAfterPolls = completeAfterPolls
        let vospace = ImageDiscoveryCoordinatorTests.MockVOSpace()
        // Mirror the realistic probe: when a launch happens, seed
        // the VOSpace fixture with a manifest at the expected path
        // so the coordinator's post-poll fetch succeeds.
        let json = Self.successManifestJSON(imageID: "test:1")
        vospace.fileContents["/arc/home/testuser/.verbinal/manifests/test_1.json"] = Data(json.utf8)
        let coord = ImageDiscoveryCoordinator(
            store: store,
            headless: headless,
            vospace: vospace,
            username: "testuser",
            probeJobTimeout: 5.0,
            pollInterval: 0.01,
            maxConcurrentProbes: 3,
            imageTypesLookup: { _ in ["headless"] }
        )
        return (coord, headless, vospace)
    }

    private static func successManifestJSON(imageID: String) -> String {
        """
        {
          "schemaVersion": 2,
          "imageID": "\(imageID)",
          "contentHash": "sha256:test",
          "capturedAt": "2026-05-19T12:00:00Z",
          "osFamily": "ubuntu",
          "osVersion": "22.04",
          "kernel": "test",
          "dpkgPackages": [],
          "rpmPackages": [],
          "apkPackages": [],
          "pythonPackages": [],
          "rPackages": [],
          "condaEnvs": [],
          "capabilities": []
        }
        """
    }

    // MARK: - Synchronous getters

    /// A freshly-built coordinator with nothing in flight reports
    /// zero. Pin so the LaunchFormView magnifier badge isn't
    /// surprised at startup.
    func testInitialCountIsZero() async {
        let (coord, _, _) = makeCoord()
        let count = await coord.inFlightCount()
        XCTAssertEqual(count, 0)
    }

    /// `inFlightImageIDs()` returns an empty array, sorted (no
    /// sentinel value).
    func testInitialImageIDsIsEmpty() async {
        let (coord, _, _) = makeCoord()
        let ids = await coord.inFlightImageIDs()
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Stream contract

    /// Subscribing yields the current count immediately. The badge
    /// renders correctly on first paint without waiting for a
    /// mutation.
    func testStreamYieldsInitialValueImmediately() async throws {
        let (coord, _, _) = makeCoord()
        let collector = StreamCollector()
        let consumer = Task {
            for await count in coord.inFlightCountChanges() {
                await collector.append(count)
                if await collector.count() >= 1 { break }
            }
        }
        try await Self.poll(timeout: 2.0) {
            await collector.count() >= 1
        }
        consumer.cancel()
        let seen = await collector.snapshot()
        XCTAssertEqual(seen.first, 0, "first yield must be the initial inFlight count (0)")
    }

    /// End-to-end: subscribe, launch a probe that keeps the job
    /// Pending for several polls so we can observe the
    /// intermediate `count == 1` state, then let it complete and
    /// confirm the stream returns to 0. Collector-based to
    /// preserve the order of mutations across actor hops.
    func testStreamReflectsLaunchAndCompletion() async throws {
        let (coord, _, _) = makeCoord(completeAfterPolls: 5)
        let collector = StreamCollector()
        let consumer = Task {
            for await count in coord.inFlightCountChanges() {
                await collector.append(count)
            }
        }

        // Let the initial yield (0) land.
        try await Self.poll(timeout: 2.0) {
            await collector.count() >= 1
        }

        // Kick off discovery; the mocked job sits Pending for
        // `completeAfterPolls` ticks before flipping to Completed,
        // giving the stream a window to surface `count == 1`.
        let discoverTask = Task {
            try await coord.discover("test:1")
        }

        // Discovery resolves; stream should have yielded 1 then 0.
        _ = try? await discoverTask.value
        try await Self.poll(timeout: 3.0) {
            let s = await collector.snapshot()
            return s.contains(1) && s.last == 0
        }
        consumer.cancel()

        let seen = await collector.snapshot()
        XCTAssertEqual(seen.first, 0, "first emission is the initial 0")
        XCTAssertTrue(seen.contains(1), "must observe count == 1 during the probe lifetime; saw \(seen)")
        XCTAssertEqual(seen.last, 0, "final emission must be 0 after cleanup; saw \(seen)")
    }

    /// `.onTermination` must drop the consumer-side continuation
    /// when the stream's caller goes away. We can't directly
    /// observe the unregister, but a clean cancel + subsequent
    /// new subscription proves the actor hasn't been left in a
    /// state that blocks new readers.
    func testStreamCleansUpOnTermination() async throws {
        let (coord, _, _) = makeCoord()

        // First subscriber: take one value and cancel.
        let firstCollector = StreamCollector()
        let firstConsumer = Task {
            for await count in coord.inFlightCountChanges() {
                await firstCollector.append(count)
                break
            }
        }
        try await Self.poll(timeout: 2.0) {
            await firstCollector.count() >= 1
        }
        firstConsumer.cancel()

        // Second subscriber should still receive the initial
        // value — proves the actor's continuations map isn't
        // wedged on the dropped first subscriber.
        let secondCollector = StreamCollector()
        let secondConsumer = Task {
            for await count in coord.inFlightCountChanges() {
                await secondCollector.append(count)
                break
            }
        }
        try await Self.poll(timeout: 2.0) {
            await secondCollector.count() >= 1
        }
        secondConsumer.cancel()

        let firstValues = await firstCollector.snapshot()
        let secondValues = await secondCollector.snapshot()
        XCTAssertEqual(firstValues, [0])
        XCTAssertEqual(secondValues, [0])
    }

    // MARK: - Test utilities

    /// Thread-safe ordered collector. Tests spawn a Task that
    /// pushes to this from inside the stream consumer; the test
    /// body reads via `snapshot()` without sharing mutable state
    /// across actor boundaries (which would trip Swift 6's
    /// captured-var rules).
    private actor StreamCollector {
        private var values: [Int] = []
        func append(_ v: Int) { values.append(v) }
        func snapshot() -> [Int] { values }
        func count() -> Int { values.count }
    }

    /// Poll `predicate` every 20ms until it returns true or
    /// `timeout` elapses. Throws on timeout. Used in lieu of
    /// `XCTestExpectation` to bridge actor-isolated state to
    /// blocking-ish test assertions without explicit
    /// fulfillment plumbing.
    private static func poll(
        timeout: TimeInterval,
        _ predicate: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("poll exceeded \(timeout)s")
    }
}
