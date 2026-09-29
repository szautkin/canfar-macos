// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// A session deleted or renewed is on the activity bar with who asked —
/// the Portal's click or an assistant's proposal (plan 17 A1: the
/// notebook1 delete could not be told apart).
@MainActor
final class SessionActionsTests: XCTestCase {

    private final class FakeSessions: SessionEnding, @unchecked Sendable {
        var deleted: [String] = []
        let refuse: Set<String>
        init(refuse: Set<String> = []) { self.refuse = refuse }
        func deleteSession(id: String) async throws {
            if refuse.contains(id) { throw URLError(.fileDoesNotExist) }
            deleted.append(id)
        }
        func renewSession(id: String) async throws {}
    }

    func testTheBarSaysWhoDeletedASession() async throws {
        let registry = TaskRegistry()
        let actions = SessionActions(service: FakeSessions(), tasks: registry)
        try await actions.delete(id: "xb0b7mu3")
        try await Initiator.$current.withValue(.assistant) { try await actions.delete(id: "notebook2") }
        try await actions.renew(id: "r1")
        XCTAssertEqual(registry.tasks.map(\.label), ["Delete session xb0b7mu3", "Delete session notebook2", "Renew session r1"])
        XCTAssertEqual(registry.tasks.map(\.startedBy), [.person, .assistant, .person])
        XCTAssertEqual(ActivitySummary.describe(registry.tasks[1]).startedBy, "Your assistant")

        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))
        let tasks = registry.tasks
        guard case .data(let data) = await ListActivityTool(tasks: { tasks }).invoke(arguments: Data("{}".utf8), context: ctx) else {
            return XCTFail()
        }
        let entries = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["tasks"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["startedBy"] as? String }, ["person", "assistant", "person"], "newest first")
    }

    func testABulkDeleteIsOneTaskThatNamesWhatFailed() async throws {
        let registry = TaskRegistry()
        let sessions = FakeSessions(refuse: ["gone"])
        let actions = SessionActions(service: sessions, tasks: registry)
        let failed = await actions.delete(ids: ["a", "gone", "b"])
        XCTAssertEqual(Set(failed.keys), ["gone"])
        XCTAssertEqual(Set(sessions.deleted), ["a", "b"])
        XCTAssertEqual(registry.tasks.count, 1)
        XCTAssertEqual(registry.tasks[0].progress, .failed)
        XCTAssertTrue(registry.tasks[0].message?.hasPrefix("Deleted 2 of 3 — gone:") == true, registry.tasks[0].message ?? "")
    }

    /// An assistant's delete_session goes through the same actions, so the
    /// Portal's rule and the bar are the assistant's too.
    func testTheAssistantsDeleteSessionIsOnTheBar() async throws {
        let registry = TaskRegistry()
        let actions = SessionActions(service: FakeSessions(), tasks: registry)
        let applier = DeleteSessionApplier(delete: { id in try await actions.delete(id: id) }, activity: AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let proposal = PendingProposal(toolName: "delete_session", kind: "delete_session", summary: "Terminate session s1",
                                       payload: try JSONEncoder().encode(DeleteSessionTool.Payload(id: "s1")),
                                       origin: .external(clientID: "t"))
        try await Initiator.$current.withValue(.assistant) { try await applier.apply(proposal) }
        XCTAssertEqual(registry.tasks.map(\.label), ["Delete session s1"])
        XCTAssertEqual(registry.tasks.first?.startedBy, .assistant)
    }
}
