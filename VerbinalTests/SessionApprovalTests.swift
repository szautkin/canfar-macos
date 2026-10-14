// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
import MCPCore
@testable import Verbinal

/// Plan 25 S: an assistant starts its session with `start_session`; the
/// person allows it, with instructions for it, or declines.
@MainActor
final class SessionApprovalTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionApprovalTests-\(UUID().uuidString)")
    }

    private func request(_ session: UUID = UUID()) -> SessionApprovals.Request {
        .init(id: session, client: "claude-code/2.1", mcpVersion: "2025-06-18", agent: "Claude",
              model: "claude-opus-5-5", purpose: "Reduce the M31 images.", askedAt: Date())
    }

    /// Answers the first request asked, once it is asked.
    private func answer(_ approvals: SessionApprovals, _ decide: @escaping (UUID) -> Void) {
        Task { @MainActor in
            for _ in 0..<200 where approvals.pending.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            if let first = approvals.pending.first { decide(first.id) }
        }
    }

    // MARK: - The approvals

    func testAllowedTheSessionIsOpenWithThePersonsInstructions() async {
        let approvals = SessionApprovals(defaults: defaults)
        let asked = request()
        answer(approvals) { approvals.allow($0, instructions: "  Only reduce; no downloads.  ") }
        guard case .allowed(let approval) = await approvals.ask(asked) else { return XCTFail("not allowed") }
        XCTAssertEqual(approval.instructions, "Only reduce; no downloads.")
        XCTAssertEqual(approvals.approval(for: asked.id), approval)
        XCTAssertTrue(approvals.pending.isEmpty)
        // Asked again, it answers at once.
        guard case .allowed = await approvals.ask(asked) else { return XCTFail("asked again") }
    }

    func testDeclinedTheSessionStaysShut() async {
        let approvals = SessionApprovals(defaults: defaults)
        let asked = request()
        answer(approvals) { approvals.decline($0) }
        let decision = await approvals.ask(asked)
        XCTAssertEqual(decision, .declined)
        XCTAssertNil(approvals.approval(for: asked.id))
        let open = await SessionApprovalGate(approvals: approvals).isOpen(asked.id)
        XCTAssertFalse(open)
    }

    /// The assistant stopped waiting: the window's request goes.
    func testAnAssistantThatStopsWaitingWithdrawsItsRequest() async throws {
        let approvals = SessionApprovals(defaults: defaults)
        let waiting = Task { await approvals.ask(self.request()) }
        for _ in 0..<200 where approvals.pending.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(approvals.pending.count, 1)
        waiting.cancel()
        let decision = await waiting.value
        XCTAssertEqual(decision, .abandoned)
        XCTAssertTrue(approvals.pending.isEmpty)
    }

    /// The app's window closed: every request waiting is declined —
    /// nobody is there to allow it.
    func testEveryRequestWaitingIsDeclinedAtOnce() async throws {
        let approvals = SessionApprovals(defaults: defaults)
        let first = Task { await approvals.ask(self.request()) }
        let second = Task { await approvals.ask(self.request()) }
        for _ in 0..<200 where approvals.pending.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        approvals.declineAll()
        let answers = [await first.value, await second.value]
        XCTAssertEqual(answers, [.declined, .declined])
        XCTAssertTrue(approvals.pending.isEmpty)
    }

    func testTheDefaultInstructionsAreThePersonsOnceSet() {
        let approvals = SessionApprovals(defaults: defaults)
        XCTAssertEqual(approvals.defaultInstructions, SessionApprovals.builtInInstructions)
        approvals.defaultInstructions = "Stay in Verbinal."
        XCTAssertEqual(SessionApprovals(defaults: defaults).defaultInstructions, "Stay in Verbinal.")
        approvals.defaultInstructions = ""
        XCTAssertEqual(approvals.defaultInstructions, SessionApprovals.builtInInstructions)
        XCTAssertEqual(SessionApprovals.words("Use only Verbinal,  and\nits tools."), 6)
    }

    // MARK: - start_session

    private final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [SessionLogEntry] = []
        func add(_ entry: SessionLogEntry) { lock.withLock { list.append(entry) } }
        var entries: [SessionLogEntry] { lock.withLock { list } }
    }

    private func context(_ session: UUID?) -> AIToolContext {
        AIToolContext(origin: .external(clientID: "claude-code/2.1"), proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(), session: session, client: "claude-code/2.1", mcpVersion: "2025-06-18")
    }

    func testStartSessionAnswersTheSessionAndTheInstructions() async throws {
        let approvals = SessionApprovals(defaults: defaults)
        let notes = Notes()
        let tool = StartSessionTool(approvals: approvals, note: { _, entry in notes.add(entry) })
        let session = UUID()
        answer(approvals) { approvals.allow($0, instructions: "Use only Verbinal.") }
        let args = Data(#"{"agent":"Claude","model":"claude-opus-5-5","purpose":"Reduce the M31 images."}"#.utf8)
        guard case .data(let data) = await tool.invoke(arguments: args, context: context(session)) else {
            return XCTFail("not started")
        }
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(out["session"] as? String, session.uuidString)
        XCTAssertEqual(out["instructions"] as? String, "Use only Verbinal.")
        let started = try XCTUnwrap(notes.entries.first)
        XCTAssertEqual(started.kind, .started)
        XCTAssertTrue(started.line.hasPrefix("The person allowed the session of Claude (claude-opus-5-5), as the assistant presents itself, here to: Reduce the M31 images."), started.line)
        XCTAssertTrue(started.line.hasSuffix("these instructions: Use only Verbinal."))
        // Again: the same session, no second window, no second entry.
        guard case .data = await tool.invoke(arguments: args, context: context(session)) else { return XCTFail() }
        XCTAssertEqual(notes.entries.count, 1)
    }

    func testDeclinedStartSessionSaysSo() async {
        let approvals = SessionApprovals(defaults: defaults)
        let notes = Notes()
        let tool = StartSessionTool(approvals: approvals, note: { _, entry in notes.add(entry) })
        answer(approvals) { approvals.decline($0) }
        let result = await tool.invoke(arguments: Data(#"{"agent":"Claude"}"#.utf8), context: context(UUID()))
        guard case .failed(.sessionDeclined) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(notes.entries.first?.outcome, "declined")
    }

    func testStartSessionIsForAConnectedAssistant() async {
        let tool = StartSessionTool(approvals: SessionApprovals(defaults: defaults), note: { _, _ in })
        let result = await tool.invoke(arguments: Data(#"{"agent":"Claude"}"#.utf8), context: context(nil))
        guard case .failed(.invalidArgument) = result else { return XCTFail("\(result)") }
    }

    // MARK: - One session per assistant (plan 34 S)

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func pass(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
    }

    private func file() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("approvals-\(UUID().uuidString).json")
    }

    /// Allows `session`, asked for by the relay of `relay`.
    private func allow(_ approvals: SessionApprovals, relay: String, instructions: String = "Use only Verbinal.") async -> UUID {
        let session = approvals.session(forRelay: relay, fresh: UUID())
        answer(approvals) { approvals.allow($0, instructions: instructions) }
        _ = await approvals.ask(request(session))
        return session
    }

    func testAnAllowedSessionOutlivesARestartOfVerbinal() async {
        let clock = Clock()
        let file = file()
        defer { try? FileManager.default.removeItem(at: file) }
        let before = SessionApprovals(defaults: defaults, file: file, now: { clock.now })
        let session = await allow(before, relay: "relay-a")
        clock.pass(minutes: 5)

        let after = SessionApprovals(defaults: defaults, file: file, now: { clock.now })
        XCTAssertEqual(after.session(forRelay: "relay-a", fresh: UUID()), session, "the relay finds its session")
        XCTAssertEqual(after.approval(for: session)?.instructions, "Use only Verbinal.")
        XCTAssertTrue(after.use(session))
        XCTAssertEqual(after.allowedSessions, [session])
        XCTAssertNotEqual(after.session(forRelay: "relay-b", fresh: UUID()), session, "another relay is another session")
        let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("secret"), "a fingerprint is kept, never a secret")
    }

    func testADeclinedOrAbandonedSessionIsNotRemembered() async throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file) }
        let approvals = SessionApprovals(defaults: defaults, file: file)
        let declined = approvals.session(forRelay: "relay-d", fresh: UUID())
        answer(approvals) { approvals.decline($0) }
        _ = await approvals.ask(request(declined))
        let waiting = Task { await approvals.ask(self.request(approvals.session(forRelay: "relay-e", fresh: UUID()))) }
        for _ in 0..<200 where approvals.pending.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        waiting.cancel()
        _ = await waiting.value

        let after = SessionApprovals(defaults: defaults, file: file)
        XCTAssertNotEqual(after.session(forRelay: "relay-d", fresh: UUID()), declined)
        XCTAssertTrue(after.allowedSessions.isEmpty)
    }

    func testASessionEndsAfterTheIdleTimeAndSaysWhy() async {
        let clock = Clock()
        let approvals = SessionApprovals(defaults: defaults, now: { clock.now })
        var endings: [SessionApprovals.Ending] = []
        approvals.onEnded = { _, why, _ in endings.append(why) }
        XCTAssertEqual(approvals.idleMinutes, 60, "an hour unless the person changes it")
        let session = await allow(approvals, relay: "relay-a")

        clock.pass(minutes: 50)
        XCTAssertTrue(approvals.use(session), "a call within the hour")
        clock.pass(minutes: 50)
        XCTAssertTrue(approvals.use(session), "the hour counts from the last call")
        XCTAssertNil(approvals.endedBecause(session))
        clock.pass(minutes: 61)
        XCTAssertFalse(approvals.use(session))
        XCTAssertEqual(approvals.endedBecause(session), "Your session ended after 1 hour without a call.")
        XCTAssertEqual(endings, [.idle])
        XCTAssertTrue(approvals.allowedSessions.isEmpty)
        XCTAssertEqual(approvals.session(forRelay: "relay-a", fresh: UUID()), session, "the relay keeps its session")

        // Asked again, the person allows the same session again.
        answer(approvals) { approvals.allow($0, instructions: "Again.") }
        guard case .allowed(let again) = await approvals.ask(request(session)) else { return XCTFail("not asked again") }
        XCTAssertEqual(again.instructions, "Again.")
        XCTAssertNil(approvals.endedBecause(session))
    }

    func testThePersonSetsTheIdleTime() async {
        let clock = Clock()
        let approvals = SessionApprovals(defaults: defaults, now: { clock.now })
        approvals.idleMinutes = 15
        XCTAssertEqual(SessionApprovals(defaults: defaults).idleMinutes, 15, "kept")
        let session = await allow(approvals, relay: "relay-a")
        clock.pass(minutes: 16)
        XCTAssertEqual(approvals.endedBecause(session), "Your session ended after 15 minutes without a call.")
        approvals.idleMinutes = 60
        XCTAssertEqual(SessionApprovals(defaults: defaults).idleMinutes, 60)
        XCTAssertEqual(SessionApprovals.idleChoices.map(SessionApprovals.idleText),
                       ["15 minutes", "1 hour", "4 hours", "12 hours", "1 day"])
    }

    func testThePersonEndsASessionOrTurnsAgentsOff() async {
        let approvals = SessionApprovals(defaults: defaults)
        let first = await allow(approvals, relay: "relay-a")
        let second = await allow(approvals, relay: "relay-b")
        approvals.end(first, .byPerson)
        XCTAssertEqual(approvals.endedBecause(first), "The person ended your session in Verbinal.")
        XCTAssertTrue(approvals.use(second))
        approvals.endAll(.agentsTurnedOff)
        XCTAssertEqual(approvals.endedBecause(second), "Your session ended when the person turned off external AI agents.")
        XCTAssertTrue(approvals.allowedSessions.isEmpty)
        let gate = SessionApprovalGate(approvals: approvals)
        let open = await gate.isOpen(second)
        XCTAssertFalse(open)
    }

    func testASecondStartSessionSaysItWasAlreadyStarted() async throws {
        let approvals = SessionApprovals(defaults: defaults)
        let tool = StartSessionTool(approvals: approvals, note: { _, _ in })
        let session = UUID()
        answer(approvals) { approvals.allow($0, instructions: "Use only Verbinal.") }
        let args = Data(#"{"agent":"Claude"}"#.utf8)
        guard case .data(let first) = await tool.invoke(arguments: args, context: context(session)),
              case .data(let second) = await tool.invoke(arguments: args, context: context(session)) else {
            return XCTFail("not started")
        }
        let one = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let two = try XCTUnwrap(JSONSerialization.jsonObject(with: second) as? [String: Any])
        XCTAssertEqual(one["alreadyStarted"] as? Bool, false)
        XCTAssertNil(one["note"])
        XCTAssertEqual(two["alreadyStarted"] as? Bool, true)
        XCTAssertEqual(two["note"] as? String, StartSessionTool.alreadyStartedNote)
        XCTAssertEqual(two["instructions"] as? String, "Use only Verbinal.")
        XCTAssertTrue(approvals.pending.isEmpty, "no second window")
    }

    // MARK: - The words (plan 25 W)

    /// Every assistant is told the same way: the server's instructions,
    /// describe_app's brief, and AGENTS.md.
    func testEveryAssistantIsToldToStartASessionTheSameWay() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let agents = try String(contentsOf: repo.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        let flat = agents.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains(AgentSession.instructions), "AGENTS.md")
        XCTAssertTrue(DescribeAppTool.brief.contains(AgentSession.instructions), "describe_app")
        XCTAssertTrue(AgentsService.serverIdentity.instructions?.hasPrefix(AgentSession.instructions) == true, "the server")
    }

    // MARK: - Its state (plan 38 P4f)

    func testASessionMovesNoneAskingActiveEnded() async {
        let approvals = SessionApprovals(defaults: defaults)
        let asked = request()
        XCTAssertEqual(approvals.state(of: asked.id), .none)
        answer(approvals) { id in
            XCTAssertEqual(approvals.state(of: id), .asking, "asking the person")
            approvals.allow(id, instructions: "Only reduce.")
        }
        guard case .allowed(let approval) = await approvals.ask(asked) else { return XCTFail("not allowed") }
        XCTAssertEqual(approvals.state(of: asked.id), .active(approval))
        approvals.end(asked.id, .byPerson)
        XCTAssertEqual(approvals.state(of: asked.id), .ended(.byPerson))
        approvals.end(asked.id, .agentsTurnedOff)
        XCTAssertEqual(approvals.state(of: asked.id), .ended(.byPerson), "an ended session does not end again")
    }

    func testTheSessionMachinesMoves() {
        typealias M = SessionMachine
        let approval = SessionApprovals.Approval(request: request(), instructions: "", allowedAt: Date())
        XCTAssertEqual(M.next(.none, on: .asked), .asking)
        XCTAssertEqual(M.next(.ended(.idle), on: .asked), .asking, "an ended session can be asked for again")
        XCTAssertEqual(M.next(.active(approval), on: .asked), .active(approval), "an allowed one is answered at once")
        XCTAssertEqual(M.next(.asking, on: .allowed(approval)), .active(approval))
        XCTAssertEqual(M.next(.asking, on: .declined), SessionApprovals.SessionState.none)
        XCTAssertNil(M.next(.none, on: .allowed(approval)), "nothing to allow")
        XCTAssertEqual(M.next(.active(approval), on: .ended(.idle)), .ended(.idle))
        XCTAssertNil(M.next(.ended(.idle), on: .ended(.byPerson)), "ends once")
        XCTAssertNil(M.next(.asking, on: .ended(.byPerson)), "only an allowed session ends")
    }
}

