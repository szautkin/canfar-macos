// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// QA's path (plan 19 S4, N7): an assistant's image probe applied in the
/// background reads `applying` — with since when — while it runs, and
/// `failed` with the probe's reason once it fails.
@MainActor
final class ProposalApplyStateTests: XCTestCase {

    /// A probe that takes a moment, then fails as a job that would not pull does.
    private struct SlowFailingProbe: ProposalApplier {
        let kind = "discover_image_packages"
        func apply(_ proposal: PendingProposal) async throws {
            try await Task.sleep(for: .milliseconds(300))
            throw ProposalApplyError.backendError("Probe job ended failed on CANFAR: Failed Error: ErrImagePull")
        }
    }

    func testABackgroundProbeReadsApplyingThenFailedWithItsReason() async throws {
        let store = InMemoryProposalStore()
        let agents = AgentsService(proposals: store)
        agents.register(appliers: [SlowFailingProbe()])
        let proposal = await store.enqueue(PendingProposal(
            toolName: "discover_image_packages", kind: "discover_image_packages", summary: "Probe x:1",
            payload: Data("{}".utf8), origin: .external(clientID: "t")))
        try await Task.sleep(for: .milliseconds(50))  // the registry takes its appliers asynchronously

        let running = Task { try await agents.applyProposal(proposal.id, by: .background) }
        for _ in 0..<50 where await store.state(proposal.id) != .applying {
            try await Task.sleep(for: .milliseconds(5))
        }
        let context = AIToolContext(origin: .external(clientID: "t"), proposals: store, budget: ProposalBudget(limit: 9))
        let args = Data(#"{"id":"\#(proposal.id.uuidString)"}"#.utf8)
        guard case .data(let during) = await GetProposalStateTool().invoke(arguments: args, context: context) else { return XCTFail() }
        let duringJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: during) as? [String: Any])
        XCTAssertEqual(duringJSON["state"] as? String, "applying")
        XCTAssertNotNil(duringJSON["applyingSince"] as? String, "applying since when")

        _ = try? await running.value
        guard case .data(let after) = await GetProposalStateTool().invoke(arguments: args, context: context) else { return XCTFail() }
        let afterJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
        XCTAssertEqual(afterJSON["state"] as? String, "failed")
        XCTAssertEqual(afterJSON["failureReason"] as? String, "Probe job ended failed on CANFAR: Failed Error: ErrImagePull")
        XCTAssertNil(afterJSON["applyingSince"])
        XCTAssertEqual(agents.applyFailures[proposal.id], "Probe job ended failed on CANFAR: Failed Error: ErrImagePull")
    }
}
