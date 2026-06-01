// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 013: the MCP-integration "restart Claude Desktop" banner
/// (didUpdateConfig) is transient — raised after a merge, cleared by the next
/// runAll() — rather than latched true forever.
@MainActor
final class MCPDiagnosticsBannerTests: XCTestCase {

    private func makeModel() -> MCPDiagnosticsModel {
        let defaults = UserDefaults(suiteName: "mcp-banner-test-\(UUID().uuidString)")!
        return MCPDiagnosticsModel(
            agents: AgentsService(),
            settings: MCPIntegrationSettingsService(defaults: defaults)  // no config access granted
        )
    }

    func testFreshModelHasNoBanner() {
        XCTAssertFalse(makeModel().didUpdateConfig)
    }

    func testRunAllClearsBanner() {
        let model = makeModel()
        model.didUpdateConfig = true   // simulate a prior merge having raised it
        model.runAll()
        XCTAssertFalse(model.didUpdateConfig, "a diagnostics refresh clears the stale restart banner")
    }

    func testFailedMergeDoesNotRaiseBanner() {
        let model = makeModel()        // no bookmark => mergeVerbinalEntry throws .noAccess
        model.applyFix(.updateConfig)
        XCTAssertFalse(model.didUpdateConfig, "a failed merge must not raise the banner")
        XCTAssertNotNil(model.actionError, "a failed merge surfaces an error")
    }
}
