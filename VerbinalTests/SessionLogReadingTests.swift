// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 23 L3: the three tools that read a session's log, and the one
/// reader behind them.
final class SessionLogReadingTests: XCTestCase {

    private var directory: URL!
    private var store: SessionLogStore!
    private var hub: AppEventHub!
    private let changes = ChangeLog()
    private let decisions = DecisionLog()
    private let session = UUID()

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessionread-\(UUID().uuidString)")
        store = SessionLogStore(directory: directory)
        hub = AppEventHub(store: store, sources: .init(requests: RequestLedger(), changes: changes, decisions: decisions)) { session, client in
            SessionLogHeader(session: session, client: client, opened: Date(), app: "1.4.0 (17)", buildCommit: nil,
                             macOS: "26.0", endpoints: [:], overridden: [], autoApply: false, signedIn: true)
        }
        await hub.opened(session, client: "claude-code/2.1")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var query: SessionLogQuery { SessionLogQuery(store: store, hub: hub) }

    private func context() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "claude-code/2.1"), proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(), session: session)
    }

    /// The assistant proposes a delete, Verbinal holds it, the person applies it.
    private func proposeHoldAndApply() async throws -> (call: UUID, proposal: PendingProposal) {
        let call = UUID()
        let proposal = PendingProposal(toolName: "delete_session", kind: "delete_session", summary: "Delete session q9p87ajc",
                                       payload: Data(), origin: .external(clientID: "claude-code/2.1"), requestID: call,
                                       why: "throwaway from the QA pass", session: session)
        await hub.callBegan(session, call: call, tool: "delete_session")
        var cause = Cause(why: proposal.why, session: session, call: call)
        cause.proposal = proposal.id
        decisions.record(.heldForPerson, "\"Delete session q9p87ajc\" waits in Pending: a delete always waits for the person",
                         subject: proposal.summary, cause: cause)
        await hub.callEnded(session, call: call, tool: "delete_session",
                            traced: .init(result: .proposed(proposal), seconds: 0.1, trace: RequestTrace(parent: nil)))
        try await Initiator.$current.withValue(.assistant) { try await changes.applying(proposal, by: .person) { } }
        await hub.settle()
        return (call, proposal)
    }

    // MARK: - get_session_log

    func testTheLogAnswersThisSessionWithNowSummaryAndEntries() async throws {
        _ = try await proposeHoldAndApply()
        let tool = GetSessionLogTool(query: query, now: { .quiet })
        let out = try await tool.handle(.init(), context: context())
        XCTAssertTrue(out.session.isThisSession)
        XCTAssertTrue(out.session.open)
        XCTAssertNotNil(out.now)
        XCTAssertEqual(out.summary.actions.done, 1)
        XCTAssertEqual(out.summary.actions.byWho, ["assistant": 1])
        XCTAssertEqual(out.summary.decisionsByRule, ["heldForPerson": 1])
        XCTAssertEqual(out.entries.map(\.kind), [.opened, .decision, .call, .action])
        XCTAssertEqual(out.nextToken, out.entries.last?.token)
    }

    func testSinceOnlyAndAboutNarrowIt() async throws {
        let (_, proposal) = try await proposeHoldAndApply()
        changes.done("vospace_mkdir", "folder data/run2 in storage")
        await hub.settle()
        let tool = GetSessionLogTool(query: query, now: { .quiet })
        let actions = try await tool.handle(.init(only: "actions"), context: context())
        XCTAssertEqual(actions.entries.count, 2)
        let about = try await tool.handle(.init(about: String(proposal.id.uuidString.prefix(8))), context: context())
        XCTAssertEqual(about.entries.map(\.kind), [.decision, .call, .action])
        let byPerson = try await tool.handle(.init(who: "person"), context: context())
        XCTAssertEqual(byPerson.entries.map(\.line).first?.hasPrefix("Made folder data/run2"), true)
        let first = try await tool.handle(.init(), context: context())
        let newer = try await tool.handle(.init(since: first.nextToken), context: context())
        XCTAssertTrue(newer.entries.isEmpty)
        XCTAssertFalse(newer.expired)
    }

    /// A task that a change already tells is folded away.
    func testATaskTheChangeTellsIsFolded() {
        let began = SessionLogEntry(token: 1, at: Date(), kind: .task, line: "Began: Delete session q", ids: .init(task: 7))
        let action = SessionLogEntry(token: 2, at: Date(), kind: .action, line: "Deleted session q", ids: .init(task: 7))
        let other = SessionLogEntry(token: 3, at: Date(), kind: .task, line: "Began: Inspect image", ids: .init(task: 8))
        XCTAssertEqual(SessionLogQuery.folded([began, action, other]).map(\.token), [2, 3])
    }

    func testAnotherSessionIsReadFromItsFile() async throws {
        let earlier = UUID()
        await hub.opened(earlier, client: "claude-code/2.0")
        await hub.closed(earlier)
        let tool = GetSessionLogTool(query: query, now: { .quiet })
        let out = try await tool.handle(.init(session: String(earlier.uuidString.prefix(8))), context: context())
        XCTAssertFalse(out.session.isThisSession)
        XCTAssertFalse(out.session.open)
        XCTAssertEqual(out.session.ending, "disconnected")
        XCTAssertNil(out.now, "now is for an open session")
    }

    // MARK: - explain_log_entry

    func testAnAppliedDeleteIsExplainedFromItsCallToItsAction() async throws {
        _ = try await proposeHoldAndApply()
        let log = try await GetSessionLogTool(query: query, now: { .quiet }).handle(.init(only: "actions"), context: context())
        let action = try XCTUnwrap(log.entries.first)
        let explanation = try await ExplainLogEntryTool(query: query).handle(.init(token: action.token), context: context())
        XCTAssertEqual(explanation.causes.map(\.kind), [.decision, .call])
        XCTAssertTrue(explanation.story.contains("Called delete_session — proposed \"Delete session q9p87ajc\""), explanation.story)
        XCTAssertTrue(explanation.story.contains("a delete always waits for the person"), explanation.story)
        XCTAssertTrue(explanation.story.contains("applied by the person, because: throwaway from the QA pass"), explanation.story)
    }

    func testTheCallIsExplainedByWhatItLedTo() async throws {
        let (call, _) = try await proposeHoldAndApply()
        guard let journal = await hub.journal(for: session) else { return XCTFail("no journal") }
        let entries = await journal.entries
        let callEntry = try XCTUnwrap(entries.first { $0.ids.call == call && $0.kind == .call })
        let explanation = try XCTUnwrap(SessionLogQuery.explain(callEntry.token, in: entries))
        XCTAssertEqual(explanation.effects.map(\.kind), [.decision, .action], "its decision, then the change")
    }

    func testAnUnknownTokenSaysWhereToLook() async {
        do {
            _ = try await ExplainLogEntryTool(query: query).handle(.init(token: 999), context: context())
            XCTFail("no such entry")
        } catch let ToolFailureReason.unknownTarget(message) {
            XCTAssertTrue(message.contains("get_session_log lists its tokens"))
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: - list_session_logs

    func testTheListMarksThisSessionAndStatesTheRule() async throws {
        let out = try await ListSessionLogsTool(query: query).handle(EmptyArgs(), context: context())
        XCTAssertEqual(out.sessions.map(\.isThisSession), [true])
        XCTAssertEqual(out.sessions.first?.open, true)
        XCTAssertEqual(out.retention, SessionLogRetention.rule)
    }

    /// A read tool's dates are ISO 8601, which an assistant can read.
    func testDatesAreWrittenAsISO8601() async throws {
        let tool = ListSessionLogsTool(query: query)
        guard case .data(let bytes) = await tool.invoke(arguments: Data("{}".utf8), context: context()) else {
            return XCTFail("no answer")
        }
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertNotNil(text.range(of: #""opened":"\d{4}-\d{2}-\d{2}T"#, options: .regularExpression), text)
    }
}
