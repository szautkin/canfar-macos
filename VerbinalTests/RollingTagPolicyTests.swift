// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class RollingTagPolicyTests: XCTestCase {

    // MARK: - Tag detection

    func testRollingTagsAreDetectedCaseInsensitively() {
        XCTAssertTrue(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:latest"))
        XCTAssertTrue(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:LATEST"))
        XCTAssertTrue(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:dev"))
        XCTAssertTrue(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:nightly"))
        XCTAssertTrue(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:main"))
        XCTAssertTrue(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:edge"))
        XCTAssertTrue(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:staging"))
        XCTAssertTrue(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:unstable"))
    }

    func testVersionedTagsAreNotRolling() {
        XCTAssertFalse(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml:24.07"))
        XCTAssertFalse(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/casa:6.5.0"))
        XCTAssertFalse(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/firefly:2025.2"))
        XCTAssertFalse(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/notebook:1.1.2"))
    }

    func testImageWithoutTagIsNotRolling() {
        XCTAssertFalse(RollingTagPolicy.isRollingTag("images.canfar.net/skaha/astroml"))
    }

    // MARK: - Staleness window

    func testFreshRollingManifestIsNotStale() {
        let m = manifest(id: "x:latest", capturedAt: Date())
        XCTAssertFalse(RollingTagPolicy.isStale(manifest: m))
    }

    func testStaleRollingManifestIsFlagged() {
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let m = manifest(id: "x:latest", capturedAt: twoDaysAgo)
        XCTAssertTrue(RollingTagPolicy.isStale(manifest: m))
    }

    func testVersionedManifestNeverGoesStale() {
        let yearAgo = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        let m = manifest(id: "x:24.07", capturedAt: yearAgo)
        XCTAssertFalse(RollingTagPolicy.isStale(manifest: m))
    }

    func testStalenessExactlyAtBoundaryIsNotStale() {
        // Window is 24h; the boundary itself is fresh. Use explicit
        // `now:` so the test isn't flaky against the microseconds
        // between capturing the two Dates.
        let now = Date()
        let exact = now.addingTimeInterval(-RollingTagPolicy.stalenessWindow)
        let m = manifest(id: "x:latest", capturedAt: exact)
        XCTAssertFalse(RollingTagPolicy.isStale(manifest: m, now: now))
    }

    func testStalenessJustOverBoundaryIsStale() {
        let now = Date()
        let over = now.addingTimeInterval(-(RollingTagPolicy.stalenessWindow + 1))
        let m = manifest(id: "x:latest", capturedAt: over)
        XCTAssertTrue(RollingTagPolicy.isStale(manifest: m, now: now))
    }

    // MARK: - Age label

    func testStaleAgeLabelReturnsNilForFresh() {
        let m = manifest(id: "x:latest", capturedAt: Date())
        XCTAssertNil(RollingTagPolicy.staleAgeLabel(for: m))
    }

    func testStaleAgeLabelDescribesAgeForStale() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        let m = manifest(id: "x:latest", capturedAt: threeDaysAgo)
        let label = RollingTagPolicy.staleAgeLabel(for: m)
        XCTAssertNotNil(label)
        XCTAssertTrue(label?.contains("3") ?? false, "got: \(label ?? "nil")")
        XCTAssertTrue(label?.lowercased().contains("rediscover") ?? false)
    }

    // MARK: - Helper

    private func manifest(id: String, capturedAt: Date) -> ImageManifest {
        ImageManifest(
            schemaVersion: 1,
            imageID: id,
            contentHash: "sha256:test",
            capturedAt: capturedAt,
            osFamily: "ubuntu",
            osVersion: "22.04",
            kernel: "Linux"
        )
    }
}
