// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// A failed job seen on this device stays seen, and the list keeps only
/// jobs still failed (plan 47 1.3).
@MainActor
final class PortalSeenStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PortalSeenStoreTests"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSeenIsKeptAcrossLaunches() {
        PortalSeenStore(defaults: defaults).markSeen(["1"], stillFailed: ["1", "2"])
        XCTAssertEqual(PortalSeenStore(defaults: defaults).seenFailedJobs, ["1"])
    }

    func testOnlyJobsStillFailedAreKept() {
        let store = PortalSeenStore(defaults: defaults)
        store.markSeen(["1", "2"], stillFailed: ["1", "2"])
        store.markSeen(["3"], stillFailed: ["2", "3"])
        XCTAssertEqual(store.seenFailedJobs, ["2", "3"], "job 1 is gone from the platform")
    }
}
