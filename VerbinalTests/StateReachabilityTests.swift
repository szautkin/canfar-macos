// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 38's tests: a machine's state is what an assistant reads — each
/// viewer's document state reaches its tool's `state`, in every state.
@MainActor
final class StateReachabilityTests: XCTestCase {
    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
    }

    private func answer(_ state: AppState, _ tool: String) async throws -> [String: Any] {
        let found = try XCTUnwrap(state.makeAgentTools().first { $0.name == tool })
        guard case .data(let data) = await found.invoke(arguments: Data("{}".utf8), context: ctx()) else {
            XCTFail("\(tool) gave no answer"); return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheFITSTabsDocumentStateIsWhatTheToolSays() async throws {
        let state = AppState()
        let tab = state.fitsTabHost.addTab()
        var json = try await answer(state, "get_fits_view")
        XCTAssertEqual(json["state"] as? String, "empty")

        tab.document.send(.begin)
        json = try await answer(state, "get_fits_view")
        XCTAssertEqual(json["state"] as? String, "opening")

        tab.document.send(.failed(Problem(.other, "not a FITS file")))
        json = try await answer(state, "get_fits_view")
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["problem"] as? String, "not a FITS file")
        XCTAssertEqual(json["isOpen"] as? Bool, false, "kept, marked for deletion")

        FITSTestFixtures.loadRamp(into: tab, path: "/tmp/reach.fits")
        json = try await answer(state, "get_fits_view")
        XCTAssertEqual(json["state"] as? String, "open")
        XCTAssertEqual(json["canvasTool"] as? String, "pan")
    }

    func testTheCubeTabsDocumentStateIsWhatTheToolSays() async throws {
        let state = AppState()
        var json = try await answer(state, "get_cube_view")
        XCTAssertEqual(json["state"] as? String, "empty")
        state.cubeViewer.document.send(.begin)
        state.cubeViewer.document.send(.failed(Problem(.other, "not a cube")))
        json = try await answer(state, "get_cube_view")
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["problem"] as? String, "not a cube")
    }
}
