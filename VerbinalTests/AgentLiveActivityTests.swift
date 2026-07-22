// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Coalescing + gating logic for the agent-activity snackbar feed.
@MainActor
final class AgentLiveActivityTests: XCTestCase {

    func testFirstCallStartsABanner() throws {
        let feed = AgentLiveActivity(enabledOverride: true)
        XCTAssertNil(feed.banner)
        feed.record(originLabel: "claude-ai/0.1", toolName: "search_observations", at: Date(timeIntervalSince1970: 0))
        let banner = try XCTUnwrap(feed.banner)
        XCTAssertEqual(banner.originLabel, "claude-ai/0.1")
        XCTAssertEqual(banner.count, 1)
        XCTAssertEqual(banner.latestTool, "search_observations")
    }

    func testRapidSameAgentCallsCoalesceIntoOneBanner() throws {
        let feed = AgentLiveActivity(enabledOverride: true)
        let t0 = Date(timeIntervalSince1970: 100)
        feed.record(originLabel: "claude-ai", toolName: "get_current_view", at: t0)
        let id0 = try XCTUnwrap(feed.banner).id
        feed.record(originLabel: "claude-ai", toolName: "search_observations", at: t0.addingTimeInterval(0.5))
        feed.record(originLabel: "claude-ai", toolName: "get_fits_view", at: t0.addingTimeInterval(1.0))
        let banner = try XCTUnwrap(feed.banner)
        XCTAssertEqual(banner.id, id0, "same burst keeps its identity")
        XCTAssertEqual(banner.count, 3)
        XCTAssertEqual(banner.latestTool, "get_fits_view", "shows the most recent tool")
    }

    func testCallOutsideBurstWindowStartsANewBanner() throws {
        let feed = AgentLiveActivity(enabledOverride: true)
        let t0 = Date(timeIntervalSince1970: 200)
        feed.record(originLabel: "claude-ai", toolName: "a", at: t0)
        let id0 = try XCTUnwrap(feed.banner).id
        // 10s later — well past the burst window.
        feed.record(originLabel: "claude-ai", toolName: "b", at: t0.addingTimeInterval(10))
        let banner = try XCTUnwrap(feed.banner)
        XCTAssertNotEqual(banner.id, id0, "a stale burst must not absorb the new call")
        XCTAssertEqual(banner.count, 1)
    }

    func testDifferentAgentStartsANewBanner() throws {
        let feed = AgentLiveActivity(enabledOverride: true)
        let t0 = Date(timeIntervalSince1970: 300)
        feed.record(originLabel: "claude-ai", toolName: "a", at: t0)
        let id0 = try XCTUnwrap(feed.banner).id
        feed.record(originLabel: "other-agent", toolName: "b", at: t0.addingTimeInterval(0.5))
        let banner = try XCTUnwrap(feed.banner)
        XCTAssertNotEqual(banner.id, id0)
        XCTAssertEqual(banner.originLabel, "other-agent")
        XCTAssertEqual(banner.count, 1)
    }

    func testDisabledFeedRecordsNothing() {
        let feed = AgentLiveActivity(enabledOverride: false)
        feed.record(originLabel: "claude-ai", toolName: "a")
        XCTAssertNil(feed.banner)
    }

    func testSetEnabledFalseClearsBanner() {
        let feed = AgentLiveActivity(enabledOverride: true)
        feed.record(originLabel: "claude-ai", toolName: "a")
        XCTAssertNotNil(feed.banner)
        feed.setEnabled(false)
        XCTAssertNil(feed.banner)
    }

    func testDismissClearsBanner() {
        let feed = AgentLiveActivity(enabledOverride: true)
        feed.record(originLabel: "claude-ai", toolName: "a")
        XCTAssertNotNil(feed.banner)
        feed.dismiss()
        XCTAssertNil(feed.banner)
    }
}
