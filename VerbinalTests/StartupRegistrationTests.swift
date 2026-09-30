// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// What the app registers as it starts is what an assistant gets. The
/// session log's tools were made before the log existed, so the app served
/// none of them — while every test that called `makeAgentTools()` after
/// startup saw all five (the person's QA, 2026-09-30).
final class StartupRegistrationTests: XCTestCase {

    private static let sessionLogTools: Set<String> = [
        "get_session_log", "explain_log_entry", "list_session_logs", "export_session_log", "delete_session_logs",
    ]

    /// The tools registered at startup, not a fresh `makeAgentTools()`.
    @MainActor
    func testStartupRegistersEveryToolTheAppMakes() {
        let state = AppState()
        let registered = Set(state.agentsService.tools.map(\.name))
        XCTAssertTrue(registered.isSuperset(of: Self.sessionLogTools),
                      "missing at startup: \(Self.sessionLogTools.subtracting(registered))")
        XCTAssertEqual(registered, Set(state.makeAgentTools().map(\.name)), "startup and a later make agree")
    }

    /// The appliers registered at startup, before anything asks again.
    @MainActor
    func testStartupRegistersTheSessionLogsAppliers() async throws {
        let state = AppState()
        var kinds: [String] = []
        for _ in 0..<100 where !kinds.contains("delete_session_logs") {
            kinds = await state.agentsService.applierRegistry.registeredKinds()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(kinds.contains("export_session_log"))
        XCTAssertTrue(kinds.contains("delete_session_logs"))
    }
}
