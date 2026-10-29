// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import MCPCore
import VerbinalKit
import XCTest
@testable import Verbinal

/// Plan 52 C: the assistants connected now, what each row says, and Close.
@MainActor
final class AssistantConnectionsTests: XCTestCase {
    private let session = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let relay = RelayIdentity(pid: 5206, started: Date(timeIntervalSince1970: 1_800_000_000), parentPID: 5181,
                                      parentName: "claude", version: "1.4.2", build: "19",
                                      executable: "/Applications/Verbinal.app/Contents/MacOS/Verbinal")

    func testTheListFollowsWhatTheBridgeTells() async {
        let clock = Clock(start)
        let list = AssistantConnections(now: { clock.now })
        let bridge = list.recorder
        await bridge.opened(session, client: "claude-code/2.1", relay: nil)
        XCTAssertEqual(list.connections.map(\.client), ["claude-code/2.1"])
        XCTAssertEqual(list.connections.first?.connected, start)

        clock.now = start.addingTimeInterval(60)
        await bridge.callBegan(session, call: UUID(), tool: "describe_app")
        await bridge.callBegan(session, call: UUID(), tool: "start_session")
        XCTAssertEqual(list.connections.first?.calls, 2)
        XCTAssertEqual(list.connections.first?.lastCall, start.addingTimeInterval(60))

        // The same relay, back after Verbinal restarted: one row, now with who it is.
        await bridge.opened(session, client: "claude-code/2.1", relay: relay)
        XCTAssertEqual(list.connections.count, 1)
        XCTAssertEqual(list.connections.first?.relay, relay)

        await bridge.closed(session)
        XCTAssertTrue(list.connections.isEmpty)
    }

    func testClosingEndsTheSessionThenTellsTheRelay() async {
        let list = AssistantConnections()
        var heard: [String] = []
        list.endSession = { heard.append("end \($0 == self.session)") }
        list.disconnect = { closed, reason in heard.append("disconnect \(closed == self.session): \(reason)") }
        await list.recorder.opened(session, client: "codex/0.9", relay: relay)
        await list.closeAll()
        XCTAssertEqual(heard, ["end true", "disconnect true: \(AssistantConnections.closedReason)"])
    }

    func testTheRowSaysWhoItsSessionItsBridgeAndItsCalls() {
        var connection = AssistantConnection(session: session, client: "claude-code/2.1", relay: relay, connected: start)
        connection.calls = 3
        connection.lastCall = start
        let request = SessionApprovals.Request(id: session, client: "claude-code/2.1", mcpVersion: nil, agent: "Claude Code",
                                               model: "claude-opus-5-5", purpose: "plan 52 QA", askedAt: start)
        let approval = SessionApprovals.Approval(request: request, instructions: "", allowedAt: start)
        let summary = AssistantConnectionSummary(connection, session: .active(approval), asking: nil,
                                                 appVersion: "1.4.2", now: start.addingTimeInterval(120))
        XCTAssertEqual(summary.title, "Claude Code (claude-opus-5-5)")
        XCTAssertEqual(summary.session, "Session allowed: plan 52 QA")
        XCTAssertEqual(summary.bridge, "Bridge 5206, launched by claude (5181), from Verbinal 1.4.2")
        XCTAssertTrue(summary.calls.hasPrefix("Calls: 3, the last "), summary.calls)
        XCTAssertEqual(summary.marks, [])
    }

    func testWithoutTheAssistantsWordsTheClientNamesIt() {
        let connection = AssistantConnection(session: session, client: "claude-code/2.1", relay: relay, connected: start)
        let summary = AssistantConnectionSummary(connection, session: .none, asking: nil, appVersion: "1.4.2", now: start)
        XCTAssertEqual(summary.title, "claude-code 2.1")
        XCTAssertEqual(summary.session, "No session yet")
        XCTAssertEqual(summary.calls, "No call yet")
    }

    func testWhatDeservesALookIsMarked() {
        var older = relay
        older.version = "1.4.1"
        let fromOlder = AssistantConnection(session: session, client: "c/1", relay: older, connected: start)
        let fromBefore = AssistantConnection(session: session, client: "c/1", relay: nil, connected: start)
        let ended = AssistantConnection(session: session, client: "c/1", relay: relay, connected: start)
        func marks(_ connection: AssistantConnection, _ state: SessionApprovals.SessionState = .none) -> [AssistantConnectionSummary.Mark] {
            AssistantConnectionSummary(connection, session: state, asking: nil, appVersion: "1.4.2", now: start).marks
        }
        XCTAssertEqual(marks(fromOlder), [.anotherVerbinal("1.4.1")])
        XCTAssertEqual(marks(fromBefore), [.cannotBeClosed(app: "c")])
        XCTAssertEqual(marks(fromBefore, .ended(.closedByPerson)), [.cannotBeClosed(app: "c")],
                       "never \"Close ends it\" where Close cannot")
        XCTAssertEqual(marks(ended, .ended(.idle)), [.sessionEnded])
        XCTAssertEqual(AssistantConnectionSummary(ended, session: .ended(.closedByPerson), asking: nil, appVersion: "1.4.2", now: start).session,
                       "Session ended: you closed its connection")
    }

    /// What Close can still do: a bridge older than 1.4.2 cannot be told to
    /// end, so once its session has ended only quitting its app ends it.
    func testCloseIsOfferedWhileItStillDoesSomething() {
        let older = AssistantConnection(session: session, client: "codex-mcp-client/0.165.0-alpha.1.2", relay: nil, connected: start)
        let newer = AssistantConnection(session: session, client: "claude-code/2.1", relay: relay, connected: start)
        func canClose(_ connection: AssistantConnection, _ state: SessionApprovals.SessionState) -> Bool {
            AssistantConnectionSummary(connection, session: state, asking: nil, appVersion: "1.4.2", now: start).canClose
        }
        XCTAssertTrue(canClose(older, .none), "it ends the session")
        XCTAssertFalse(canClose(older, .ended(.closedByPerson)))
        XCTAssertTrue(canClose(newer, .ended(.idle)), "it ends the bridge")
        XCTAssertEqual(AssistantConnectionSummary.Mark.cannotBeClosed(app: older.clientName).text,
                       "Its bridge is from a Verbinal older than 1.4.2, which can't be closed from here: quit the assistant's app (codex-mcp-client) to end it.")
    }

    func testTheLogSaysWhichBridgeAnAssistantCameThrough() {
        XCTAssertEqual(SessionLogLine.through(relay), ", through its bridge (pid 5206, launched by claude, pid 5181)")
        XCTAssertEqual(SessionLogLine.through(nil), "")
        XCTAssertTrue(SessionLogLine.reconnected("codex/0.9", session: session, relay: relay).line.contains("through its bridge (pid 5206"))
    }

    /// C7: an assistant reads its own connection, never another's.
    func testDescribeAppTellsTheCallerItsOwnConnection() async throws {
        let mine = AssistantConnection(session: session, client: "codex/0.9", relay: relay, connected: start)
        var tool = DescribeAppTool()
        tool.connection = { [session] asked in asked == session ? mine : nil }
        func context(_ session: UUID?) -> AIToolContext {
            AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9),
                          session: session)
        }
        let own = try await tool.handle(.init(app: nil), context: context(session))
        XCTAssertEqual(own.connection?.bridgeVersion, "1.4.2")
        XCTAssertEqual(own.connection?.since, start.ISO8601Format())
        let other = try await tool.handle(.init(app: nil), context: context(UUID()))
        XCTAssertNil(other.connection)
    }

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
}
