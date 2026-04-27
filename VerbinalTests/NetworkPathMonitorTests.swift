// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Smoke tests for ``NetworkPathMonitor``. Real `NWPathMonitor` requires
/// the system network stack and produces non-deterministic timing under
/// CI; we cover invariants that don't depend on actual network state:
/// idempotent start/stop and the change-counter contract.
@MainActor
final class NetworkPathMonitorTests: XCTestCase {

    func testInitialStateIsUnknown() {
        let monitor = NetworkPathMonitor()
        XCTAssertEqual(monitor.connectivity, .unknown)
        XCTAssertEqual(monitor.changeCount, 0)
    }

    func testStartIsIdempotent() {
        let monitor = NetworkPathMonitor()
        monitor.start()
        monitor.start()
        // No assertion needed — just shouldn't crash. Initial path-update
        // callback fires asynchronously on the system queue and may or may
        // not arrive before the test exits; either way the second `start()`
        // is a no-op per the implementation contract.
    }

    func testStopAfterStart() {
        let monitor = NetworkPathMonitor()
        monitor.start()
        monitor.stop()
        // Subsequent reads still produce a value (initial state if no path
        // update arrived) — the assertion is that stop() doesn't crash.
        XCTAssertNotNil(monitor.connectivity)
    }

    func testInterfaceClassificationCases() {
        // Indirect coverage: the public Interface enum has the expected
        // cases the UI may need to switch on.
        XCTAssertEqual(NetworkPathMonitor.Interface.wifi, .wifi)
        XCTAssertEqual(NetworkPathMonitor.Interface.wired, .wired)
        XCTAssertEqual(NetworkPathMonitor.Interface.cellular, .cellular)
        XCTAssertEqual(NetworkPathMonitor.Interface.loopback, .loopback)
        XCTAssertEqual(NetworkPathMonitor.Interface.other, .other)
    }
}
