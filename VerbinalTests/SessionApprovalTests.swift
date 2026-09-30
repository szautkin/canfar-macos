// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
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
}
