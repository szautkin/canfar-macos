// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Ticket 021: a session launch that returns no ID must be reported as a
/// failure — not a "Session launched! ID: unknown" success with a junk
/// RecentLaunch queued.
@MainActor
final class SessionLaunchModelTests: XCTestCase {

    private struct StubLauncher: SessionLaunching {
        let result: String?
        func launchSession(_ params: SessionLaunchParams) async throws -> String? { result }
    }

    private func makeModel(returning id: String?) -> SessionLaunchModel {
        let model = SessionLaunchModel(
            sessionService: StubLauncher(result: id),
            imageService: ImageService(network: NetworkClient(session: .shared)),
            recentLaunchStore: RecentLaunchStore()
        )
        model.selectedImage = ImageParser.parse(
            RawImage(id: "images.canfar.net/skaha/notebook:1.0", types: ["notebook"])
        )
        model.sessionName = "test-session"
        return model
    }

    func testLaunchFailsWhenNoSessionID() async {
        let model = makeModel(returning: nil)
        await model.launch()
        XCTAssertFalse(model.launchSuccess, "a no-ID launch must not report success")
        XCTAssertTrue(model.hasError)
        XCTAssertNil(model.pendingRecentLaunch, "no RecentLaunch should be queued for a no-ID launch")
    }

    func testLaunchSucceedsWithSessionID() async {
        let model = makeModel(returning: "sess-abc123")
        await model.launch()
        XCTAssertTrue(model.launchSuccess)
        XCTAssertTrue(model.launchStatus.contains("sess-abc123"), "status should carry the real id")
        XCTAssertEqual(model.pendingRecentLaunch?.name, "test-session")
    }
}
