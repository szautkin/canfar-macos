// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// The robot that opens Pending — where destructive changes always wait —
/// is in every toolbar, Landing and Portal included, agents on or not
/// (plan 17 U1, QA N11).
@MainActor
final class PendingChangesToolbarTests: XCTestCase {

    private func targets(in mode: AppMode) async throws -> Set<String> {
        let state = AppState()
        state.currentMode = mode
        return try await HostedContentView.pointTargets(state, waitingFor: "agent.pending")
    }

    func testTheRobotIsOnLandingAndPortal() async throws {
        let landing = try await targets(in: .landing)
        XCTAssertTrue(landing.contains("agent.pending"), "Landing: \(landing.sorted())")
        let portal = try await targets(in: .portal)
        XCTAssertTrue(portal.contains("agent.pending"), "Portal: \(portal.sorted())")
        let search = try await targets(in: .search)
        XCTAssertTrue(search.contains("agent.pending"), "Search: \(search.sorted())")
    }
}
