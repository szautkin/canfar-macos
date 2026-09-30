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
        let listed: Set<String>
        let refuse: Set<String>
        init(listed: Set<String> = ["xb0b7mu3", "notebook2", "r1", "a", "b", "s1"], refuse: Set<String> = []) {
            (self.listed, self.refuse) = (listed, refuse)
        }
        /// As CANFAR does: a DELETE of an id it does not have succeeds.
        func deleteSession(id: String) async throws {
            if refuse.contains(id) { throw URLError(.cannotConnectToHost) }
            deleted.append(id)
        }
        func deleteDesktopApp(session: String, app: String) async throws {
            deleted.append("\(session)/\(app)")
        }
        func renewSession(id: String) async throws {}
        func listing() async throws -> [ListedSession] {
            listed.map { ListedSession(id: $0, type: "notebook") }
                + [ListedSession(id: "d1", type: "desktop"), ListedSession(id: "d1", type: "desktop-app", appid: "a7")]
        }
    }

    /// Plan 23 aside (the person, 2026-09-30): one desktop app is stopped by
    /// its own delete; an app a desktop does not have is said so, never sent.
    func testADesktopAppIsStoppedOnItsOwn() async throws {
        let sessions = FakeSessions()
        let actions = SessionActions(service: sessions, tasks: TaskRegistry())
        try await actions.delete(id: "d1", app: "a7")
        XCTAssertEqual(sessions.deleted, ["d1/a7"])
        do {
            try await actions.delete(id: "d1", app: "nope")
            XCTFail("no such app")
        } catch let error as NoSuchDesktopApp {
            XCTAssertEqual(error, NoSuchDesktopApp(session: "d1", app: "nope"))
        }
        XCTAssertEqual(sessions.deleted, ["d1/a7"], "never sent")
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
        let sessions = FakeSessions(refuse: ["b"])
        let actions = SessionActions(service: sessions, tasks: registry)
        let failed = await actions.delete(ids: ["a", "typo", "b"])
        XCTAssertEqual(Set(failed.keys), ["typo", "b"])
        XCTAssertEqual(sessions.deleted, ["a"], "an id the platform does not list is never sent")
        XCTAssertEqual(registry.tasks.count, 1)
        XCTAssertEqual(registry.tasks[0].progress, .failed)
        let message = registry.tasks[0].message ?? ""
        XCTAssertTrue(message.hasPrefix("Deleted 1 of 3 — ") && message.contains("typo: no such session typo"), message)
    }

    /// Plan 19 S1 (QA N20): "Deleted 2 of 2" for a made-up id — CANFAR
    /// answers a DELETE of an unknown id with success.
    func testAnIdThePlatformDoesNotListIsNotDeleted() async throws {
        let registry = TaskRegistry()
        let sessions = FakeSessions()
        let actions = SessionActions(service: sessions, tasks: registry)
        do {
            try await actions.delete(id: "qa-typo")
            XCTFail("an unknown id is not deleted")
        } catch let error as NoSuchSession {
            XCTAssertEqual(error, NoSuchSession(id: "qa-typo"))
        }
        XCTAssertTrue(sessions.deleted.isEmpty)
        XCTAssertEqual(registry.tasks.first?.progress, .failed)
    }

    /// An assistant's delete_session goes through the same actions, so the
    /// Portal's rule and the bar are the assistant's too.
    func testTheAssistantsDeleteSessionIsOnTheBar() async throws {
        let registry = TaskRegistry()
        let actions = SessionActions(service: FakeSessions(), tasks: registry)
        let applier = DeleteSessionApplier(delete: { id, app in try await actions.delete(id: id, app: app) }, activity: AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let proposal = PendingProposal(toolName: "delete_session", kind: "delete_session", summary: "Terminate session s1",
                                       payload: try JSONEncoder().encode(DeleteSessionTool.Payload(id: "s1")),
                                       origin: .external(clientID: "t"))
        try await Initiator.$current.withValue(.assistant) { try await applier.apply(proposal) }
        XCTAssertEqual(registry.tasks.map(\.label), ["Delete session s1"])
        XCTAssertEqual(registry.tasks.first?.startedBy, .assistant)
    }

    /// Plan 21 N4: a failed delete applied again showed as the same line
    /// twice; the second says it is a retry.
    func testATaskThatRepeatsAFailedOneSaysSo() async throws {
        let registry = TaskRegistry()
        let actions = SessionActions(service: FakeSessions(), tasks: registry)
        for _ in 0..<2 { try? await actions.delete(id: "no-such-session-qa") }
        XCTAssertEqual(registry.tasks.map(\.isAgain), [false, true])
        XCTAssertEqual(ActivitySummary.describe(registry.tasks[1]).title, "Delete session no-such-session-qa, again")
        try await actions.renew(id: "r1")
        XCTAssertFalse(registry.tasks[2].isAgain, "only a repeat of a failure")
    }
}
