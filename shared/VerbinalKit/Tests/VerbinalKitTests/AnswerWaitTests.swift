// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// Plan 30 L: no answer takes longer than `RequestTimeout.answer` (45 s,
/// the person's decision) — an assistant's client may give up at 60 s —
/// and the work goes on past it, shown, instead of being cut off.
final class AnswerWaitTests: XCTestCase {

    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var _finished = false
        private var _carried: [String] = []
        private var _ended: [Bool] = []
        var finished: Bool { lock.withLock { _finished } }
        var carried: [String] { lock.withLock { _carried } }
        var ended: [Bool] { lock.withLock { _ended } }
        func finish() { lock.withLock { _finished = true } }
        func carry(_ tool: String) { lock.withLock { _carried.append(tool) } }
        func end(_ ok: Bool) { lock.withLock { _ended.append(ok) } }
    }

    private struct SlowTool: AITool {
        static let verbClass: VerbClass = .read
        static let agentSafe: Bool = true
        let ran: Ran
        let definition = AIToolDefinition.withStaticSchema(
            name: "slow", description: "Takes a while", schema: #"{"type":"object","properties":{}}"#)
        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            try? await Task.sleep(for: .milliseconds(600))
            ran.finish()
            return .data(Data("{}".utf8))
        }
    }

    func testTheAnswerComesInTimeAndTheWorkGoesOn() async throws {
        XCTAssertEqual(RequestTimeout.answer, 45)
        let ran = Ran()
        let router = AIToolRouter(
            tools: [SlowTool(ran: ran)], auditSink: CapturingAuditSink(),
            onCarryOn: { tool, _ in ran.carry(tool); return { failure in ran.end(failure == nil) } },
            answerWait: 0.15)
        let started = Date()
        let result = await router.dispatch(name: "slow", rawArguments: Data("{}".utf8),
                                           context: AIToolContext(origin: .external(clientID: "t"),
                                                                  proposals: InMemoryProposalStore(),
                                                                  budget: ProposalBudget(limit: 8)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "answered at the wait, not when the work ended")
        guard case .failed(.backendError(let message)) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(message.contains("slow has not answered in 0 s"), message)
        XCTAssertTrue(message.contains("it carries on in Verbinal, on the activity bar"), message)
        XCTAssertFalse(ran.finished, "not finished yet")

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(ran.finished, "the work was not cut off")
        XCTAssertEqual(ran.carried, ["slow"], "shown while it carried on")
        XCTAssertEqual(ran.ended, [true], "and told when it ended")
    }

    func testAQuickAnswerIsNotCarriedOn() async throws {
        let ran = Ran()
        let router = AIToolRouter(
            tools: [SlowTool(ran: ran)], auditSink: CapturingAuditSink(),
            onCarryOn: { tool, _ in ran.carry(tool); return { failure in ran.end(failure == nil) } },
            answerWait: 5)
        let result = await router.dispatch(name: "slow", rawArguments: Data("{}".utf8),
                                           context: AIToolContext(origin: .external(clientID: "t"),
                                                                  proposals: InMemoryProposalStore(),
                                                                  budget: ProposalBudget(limit: 8)))
        guard case .data = result else { return XCTFail("\(result)") }
        XCTAssertTrue(ran.carried.isEmpty)
    }

    private struct FailingSlowTool: AITool {
        static let verbClass: VerbClass = .read
        static let agentSafe: Bool = true
        let definition = AIToolDefinition.withStaticSchema(
            name: "slowFail", description: "Takes a while, then fails", schema: #"{"type":"object","properties":{}}"#)
        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            try? await Task.sleep(for: .milliseconds(400))
            return .failed(.backendError("the CADC archive search did not answer in time"))
        }
    }

    final class Ends: @unchecked Sendable {
        private let lock = NSLock()
        private var _failures: [String?] = []
        var failures: [String?] { lock.withLock { _failures } }
        func end(_ failure: String?) { lock.withLock { _failures.append(failure) } }
    }

    /// A call that carries on and then fails says why on the activity bar —
    /// not "it ended without an answer" (handout 31).
    func testWorkThatFailsAfterItsAnswerSaysWhy() async throws {
        let ends = Ends()
        let router = AIToolRouter(
            tools: [FailingSlowTool()], auditSink: CapturingAuditSink(),
            onCarryOn: { _, _ in { failure in ends.end(failure) } },
            answerWait: 0.1)
        _ = await router.dispatch(name: "slowFail", rawArguments: Data("{}".utf8),
                                  context: AIToolContext(origin: .external(clientID: "t"),
                                                         proposals: InMemoryProposalStore(),
                                                         budget: ProposalBudget(limit: 8)))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(ends.failures, ["the CADC archive search did not answer in time"])
        XCTAssertEqual(ToolFailureReason.authRequired.message, "authRequired", "one with no words keeps its tag")
    }
}
