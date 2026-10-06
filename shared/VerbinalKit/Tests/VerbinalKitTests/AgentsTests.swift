// SPDX-License-Identifier: MPL-2.0

import XCTest
import os.log
@testable import VerbinalKit
@testable import MCPCore

// MARK: - Test doubles

private struct EchoReadTool: AITool {
    static let verbClass: VerbClass = .read
    static let agentSafe: Bool = true

    let definition = AIToolDefinition.withStaticSchema(
        name: "echo",
        description: "Returns its arguments verbatim",
        schema: #"{"type":"object","properties":{}}"#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        return .data(arguments)
    }
}

/// Answers with who the router says is acting.
private struct WhoTool: AITool {
    static let verbClass: VerbClass = .read
    static let agentSafe: Bool = true

    let definition = AIToolDefinition.withStaticSchema(
        name: "who", description: "Says who is acting", schema: #"{"type":"object","properties":{}}"#)

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let inner = await Task { Initiator.current }.value
        return .data(Data("\(Initiator.current.rawValue),\(inner.rawValue)".utf8))
    }
}

private struct StrictReadTool: AITool {
    static let verbClass: VerbClass = .read
    static let agentSafe: Bool = true

    let definition = AIToolDefinition.withStaticSchema(
        name: "strict",
        description: "Rejects undeclared arguments",
        schema: #"""
        {
          "type": "object",
          "properties": { "foo_bar": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        .data(arguments)
    }
}

private struct WriteSentinelTool: AITool {
    static let verbClass: VerbClass = .semanticWrite
    static let agentSafe: Bool = true

    let definition = AIToolDefinition.withStaticSchema(
        name: "write_sentinel",
        description: "Always proposes a no-op write so we can pin the budget gate.",
        schema: #"{"type":"object","properties":{}}"#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let proposal = PendingProposal(
            toolName: "write_sentinel",
            kind: "sentinel",
            summary: "no-op",
            payload: Data("{}".utf8),
            origin: context.origin
        )
        let queued = await context.proposals.enqueue(proposal)
        return .proposed(queued)
    }
}

private struct UserOnlyTool: AITool {
    static let verbClass: VerbClass = .undo
    static let agentSafe: Bool = false

    let definition = AIToolDefinition.withStaticSchema(
        name: "user_only",
        description: "Not exposed to external agents.",
        schema: #"{"type":"object","properties":{}}"#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        .data(Data("{}".utf8))
    }
}

/// Thread-safe recorder for the router's `onDispatchStart` callback.
private final class DispatchStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(tool: String, label: String)] = []
    func append(tool: String, label: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append((tool, label))
    }
    func snapshot() -> [(tool: String, label: String)] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

// MARK: - Router tests

final class AIToolRouterTests: XCTestCase {

    private func makeRouter(
        _ tools: [any AITool],
        sink: any AuditSink = CapturingAuditSink()
    ) -> AIToolRouter {
        AIToolRouter(tools: tools, auditSink: sink)
    }

    private func ctx(_ origin: OperationOrigin = .external(clientID: "test"),
                     proposals: any ProposalStore = InMemoryProposalStore(),
                     budget: ProposalBudget = ProposalBudget(limit: 8)) -> AIToolContext {
        AIToolContext(origin: origin, proposals: proposals, budget: budget)
    }

    /// Plan 17 A1: what an assistant's call sets going is the assistant's,
    /// down to the tasks it starts; the person's own calls stay theirs.
    func testAnAssistantsCallActsAsTheAssistant() async {
        let router = makeRouter([WhoTool()])
        for (origin, expected) in [(OperationOrigin.external(clientID: "t"), "assistant,assistant"),
                                   (.user, "person,person")] {
            guard case .data(let bytes) = await router.dispatch(name: "who", rawArguments: Data("{}".utf8),
                                                                  context: ctx(origin)) else {
                return XCTFail("expected .data")
            }
            XCTAssertEqual(String(data: bytes, encoding: .utf8), expected)
        }
        XCTAssertEqual(Initiator.current, .person, "outside a call, the person")
    }

    func testReadToolReturnsData() async {
        let router = makeRouter([EchoReadTool()])
        let result = await router.dispatch(
            name: "echo",
            rawArguments: Data(#"{"x":1}"#.utf8),
            context: ctx()
        )
        guard case .data(let bytes) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(String(data: bytes, encoding: .utf8), #"{"x":1}"#)
    }

    func testExternalDispatchFiresDispatchStartEvenWhenCallFails() async {
        // Windows RouterTests parity: the "agent is working" pulse fires
        // at dispatch START for external callers — including calls that
        // ultimately fail (unknown tool here).
        let started = CapturingAuditSink() // reuse as a thread-safe flag store
        let box = DispatchStartBox()
        let router = AIToolRouter(
            tools: [EchoReadTool()],
            auditSink: started,
            onDispatchStart: { tool, label in box.append(tool: tool, label: label) }
        )
        _ = await router.dispatch(name: "nope", rawArguments: Data("{}".utf8), context: ctx())
        _ = await router.dispatch(name: "echo", rawArguments: Data("{}".utf8), context: ctx())
        XCTAssertEqual(box.snapshot().map(\.tool), ["nope", "echo"])
        XCTAssertEqual(box.snapshot().first?.label, "test")
    }

    func testUserOriginDoesNotFireDispatchStart() async {
        let box = DispatchStartBox()
        let router = AIToolRouter(
            tools: [EchoReadTool()],
            auditSink: CapturingAuditSink(),
            onDispatchStart: { tool, label in box.append(tool: tool, label: label) }
        )
        _ = await router.dispatch(name: "echo", rawArguments: Data("{}".utf8),
                                  context: ctx(.user))
        XCTAssertTrue(box.snapshot().isEmpty, "in-app calls must not pulse the agent indicator")
    }

    func testUnknownToolReturnsUnknownTarget() async {
        let router = makeRouter([EchoReadTool()])
        let result = await router.dispatch(
            name: "nope",
            rawArguments: Data("{}".utf8),
            context: ctx()
        )
        guard case .failed(.unknownTarget(let what)) = result else {
            return XCTFail("expected unknownTarget, got \(result)")
        }
        XCTAssertEqual(what, "nope")
    }

    func testAdditionalPropertiesFalseRejectsUnknownArguments() async {
        let router = makeRouter([StrictReadTool()])
        let rejected = await router.dispatch(
            name: "strict",
            rawArguments: Data(#"{"foo":"ok","typo":1}"#.utf8),
            context: ctx()
        )
        guard case .failed(.invalidArgument(let msg)) = rejected else {
            return XCTFail("expected invalidArgument, got \(rejected)")
        }
        XCTAssertTrue(msg.contains("typo"), msg)
        XCTAssertTrue(msg.contains("strict"), msg)

        let aliased = await router.dispatch(
            name: "strict",
            rawArguments: Data(#"{"fooBar":"ok"}"#.utf8),
            context: ctx()
        )
        guard case .data(let echoed) = aliased else {
            return XCTFail("camelCase of a declared snake_case name must pass the gate, got \(aliased)")
        }
        // The tool decodes the declared spelling only, so it must receive that.
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), #"{"foo_bar":"ok"}"#)

        let ok = await router.dispatch(
            name: "strict",
            rawArguments: Data(#"{"foo_bar":"ok"}"#.utf8),
            context: ctx()
        )
        guard case .data = ok else {
            return XCTFail("declared name must pass, got \(ok)")
        }
    }

    func testUserOnlyToolHiddenFromExternal() async {
        let router = makeRouter([UserOnlyTool()])
        let manifest = await router.externalManifestList()
        XCTAssertTrue(manifest.isEmpty)

        // External invocation returns unknownTarget (defence in depth — the
        // bridge already filters via the manifest).
        let result = await router.dispatch(
            name: "user_only",
            rawArguments: Data("{}".utf8),
            context: ctx(.external(clientID: "external"))
        )
        guard case .failed(.unknownTarget) = result else {
            return XCTFail("expected unknownTarget")
        }
    }

    func testUserOnlyToolUsableByUser() async {
        let router = makeRouter([UserOnlyTool()])
        let result = await router.dispatch(
            name: "user_only",
            rawArguments: Data("{}".utf8),
            context: ctx(.user)
        )
        guard case .data = result else {
            return XCTFail("expected data, got \(result)")
        }
    }

    func testProposalBudgetWithdrawsOnExceeded() async {
        let store = InMemoryProposalStore()
        let budget = ProposalBudget(limit: 2)
        let router = makeRouter([WriteSentinelTool()])

        let context = ctx(.external(clientID: "agent-A"), proposals: store, budget: budget)

        // Two writes succeed.
        for _ in 0..<2 {
            let r = await router.dispatch(name: "write_sentinel",
                                          rawArguments: Data("{}".utf8),
                                          context: context)
            guard case .proposed = r else {
                return XCTFail("expected proposed, got \(r)")
            }
        }
        // Third exceeds; the proposal should be withdrawn from the store.
        let third = await router.dispatch(name: "write_sentinel",
                                          rawArguments: Data("{}".utf8),
                                          context: context)
        guard case .failed(.perTurnProposalCapExceeded(let lim)) = third else {
            return XCTFail("expected cap exceeded, got \(third)")
        }
        XCTAssertEqual(lim, 2)
        let pending = await store.list(origin: nil)
        XCTAssertEqual(pending.count, 2, "withdrawn proposal must not remain in queue")
    }

    // MARK: - Auto-apply hook

    private actor ApplyCallCounter {
        var count = 0
        var lastID: UUID?
        var shouldThrow = false

        func setShouldThrow(_ v: Bool) { shouldThrow = v }

        func bumpAndRecord(_ id: UUID) throws {
            count += 1
            lastID = id
            if shouldThrow {
                throw ProposalApplyError.backendError("boom")
            }
        }
    }

    func testAutoApplyHookConvertsProposalToData() async throws {
        let counter = ApplyCallCounter()
        let store = InMemoryProposalStore()
        let hook = AutoApplyHook(
            shouldAutoApply: { _, _ in true },
            apply: { id in
                try await counter.bumpAndRecord(id)
                _ = await store.markApplied(id, by: .person)
                return nil
            }
        )
        let router = AIToolRouter(
            tools: [WriteSentinelTool()],
            auditSink: CapturingAuditSink(),
            autoApplyHook: hook
        )
        let context = ctx(.external(clientID: "trusted"),
                          proposals: store,
                          budget: ProposalBudget(limit: 8))

        let result = await router.dispatch(name: "write_sentinel",
                                           rawArguments: Data("{}".utf8),
                                           context: context)

        guard case .data(let bytes) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        let ack = try JSONDecoder().decode(AutoAppliedAck.self, from: bytes)
        XCTAssertTrue(ack.applied)
        XCTAssertEqual(ack.kind, "sentinel")

        let calls = await counter.count
        XCTAssertEqual(calls, 1)

        // Auto-apply path should NOT consume budget — verify the next
        // call still goes through (with limit=1 we'd otherwise be
        // capped if budget had been touched).
        let budget = ProposalBudget(limit: 1)
        let context2 = ctx(.external(clientID: "trusted-2"),
                           proposals: InMemoryProposalStore(),
                           budget: budget)
        for _ in 0..<3 {
            let r = await router.dispatch(name: "write_sentinel",
                                          rawArguments: Data("{}".utf8),
                                          context: context2)
            guard case .data = r else {
                return XCTFail("auto-apply should bypass budget; got \(r)")
            }
        }
    }

    func testAutoApplyHookFalsePreservesStripPath() async {
        let store = InMemoryProposalStore()
        let counter = ApplyCallCounter()
        let hook = AutoApplyHook(
            shouldAutoApply: { _, _ in false },
            apply: { id in try await counter.bumpAndRecord(id); return nil }
        )
        let router = AIToolRouter(
            tools: [WriteSentinelTool()],
            auditSink: CapturingAuditSink(),
            autoApplyHook: hook
        )
        let context = ctx(.external(clientID: "untrusted"),
                          proposals: store,
                          budget: ProposalBudget(limit: 8))

        let result = await router.dispatch(name: "write_sentinel",
                                           rawArguments: Data("{}".utf8),
                                           context: context)

        guard case .proposed = result else {
            return XCTFail("expected .proposed when hook says no, got \(result)")
        }
        let calls = await counter.count
        XCTAssertEqual(calls, 0, "apply must not run when hook says no")
    }

    func testAutoApplyHookFailureWithdrawsProposal() async {
        let store = InMemoryProposalStore()
        let counter = ApplyCallCounter()
        await counter.setShouldThrow(true)
        let hook = AutoApplyHook(
            shouldAutoApply: { _, _ in true },
            apply: { id in try await counter.bumpAndRecord(id); return nil }
        )
        let router = AIToolRouter(
            tools: [WriteSentinelTool()],
            auditSink: CapturingAuditSink(),
            autoApplyHook: hook
        )
        let context = ctx(.external(clientID: "trusted"),
                          proposals: store,
                          budget: ProposalBudget(limit: 8))

        let result = await router.dispatch(name: "write_sentinel",
                                           rawArguments: Data("{}".utf8),
                                           context: context)

        guard case .failed(.backendError) = result else {
            return XCTFail("expected backendError on apply throw, got \(result)")
        }
        // A deterministically failing auto-apply must withdraw the
        // optimistic proposal (mirroring the budget-cap path) so it
        // can't linger in the queue only to fail again.
        let pending = await store.list(origin: nil)
        XCTAssertTrue(pending.isEmpty, "failed auto-apply must withdraw the proposal, not leave it queued")
    }

    func testAuditSinkRecordsEachCall() async {
        let sink = CapturingAuditSink()
        let router = makeRouter([EchoReadTool()], sink: sink)
        _ = await router.dispatch(name: "echo",
                                  rawArguments: Data(#"{"k":"v"}"#.utf8),
                                  context: ctx())
        let entries = sink.snapshot()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.toolName, "echo")
        XCTAssertEqual(entry.verbClass, .read)
        XCTAssertEqual(entry.outcome, .data)
        XCTAssertNotEqual(entry.payloadHash, "empty")
        XCTAssertEqual(entry.payloadHash.count, 64) // full SHA-256 hex
    }

    func testAuditOriginFingerprintsExternal() {
        let user = AuditOrigin.from(.user)
        XCTAssertEqual(user.tag, "user")
        let agent = AuditOrigin.from(.external(clientID: "claude/0.1"))
        // Fingerprint stable across calls with same input.
        XCTAssertEqual(agent, AuditOrigin.from(.external(clientID: "claude/0.1")))
        XCTAssertNotEqual(agent, AuditOrigin.from(.external(clientID: "other/1.0")))
    }
}

// MARK: - Budget tests

final class ProposalBudgetTests: XCTestCase {

    func testTryAcceptCountsTowardLimit() async {
        let budget = ProposalBudget(limit: 3)
        let origin: OperationOrigin = .external(clientID: "x")
        for _ in 0..<3 {
            let ok = await budget.tryAccept(origin: origin)
            XCTAssertTrue(ok)
        }
        let denied = await budget.tryAccept(origin: origin)
        XCTAssertFalse(denied)
    }

    func testRemainingTracksUsage() async {
        let budget = ProposalBudget(limit: 5)
        let origin: OperationOrigin = .user
        let beforeRemaining = await budget.remaining(for: origin)
        XCTAssertEqual(beforeRemaining, 5)
        _ = await budget.tryAccept(origin: origin)
        let afterRemaining = await budget.remaining(for: origin)
        XCTAssertEqual(afterRemaining, 4)
    }

    func testResetRestoresFullLimit() async {
        let budget = ProposalBudget(limit: 2)
        let origin: OperationOrigin = .external(clientID: "y")
        _ = await budget.tryAccept(origin: origin)
        _ = await budget.tryAccept(origin: origin)
        let blocked = await budget.tryAccept(origin: origin)
        XCTAssertFalse(blocked)
        await budget.reset(origin: origin)
        let afterReset = await budget.tryAccept(origin: origin)
        XCTAssertTrue(afterReset)
    }

    func testOriginsAreSeparateBuckets() async {
        let budget = ProposalBudget(limit: 1)
        let a: OperationOrigin = .external(clientID: "a")
        let b: OperationOrigin = .external(clientID: "b")
        let firstA = await budget.tryAccept(origin: a)
        XCTAssertTrue(firstA)
        let secondA = await budget.tryAccept(origin: a)
        XCTAssertFalse(secondA)
        let firstB = await budget.tryAccept(origin: b)
        XCTAssertTrue(firstB) // separate bucket
    }
}

// MARK: - Store tests

final class InMemoryProposalStoreTests: XCTestCase {

    private func makeProposal(_ origin: OperationOrigin = .user) -> PendingProposal {
        PendingProposal(
            toolName: "tool",
            kind: "kind",
            summary: "summary",
            payload: Data("{}".utf8),
            origin: origin
        )
    }

    func testEnqueueAndList() async {
        let store = InMemoryProposalStore()
        let p = await store.enqueue(makeProposal())
        let list = await store.list(origin: nil)
        XCTAssertEqual(list.map(\.id), [p.id])
    }

    func testListFiltersByOrigin() async {
        let store = InMemoryProposalStore()
        _ = await store.enqueue(makeProposal(.user))
        _ = await store.enqueue(makeProposal(.external(clientID: "c")))
        let userOnly = await store.list(origin: .user)
        XCTAssertEqual(userOnly.count, 1)
    }

    func testStateTransitions() async {
        let store = InMemoryProposalStore()
        let p = await store.enqueue(makeProposal())
        let initialState = await store.state(p.id)
        XCTAssertEqual(initialState, .pending)
        let applied = await store.markApplied(p.id, by: .person)
        XCTAssertTrue(applied)
        let finalState = await store.state(p.id)
        XCTAssertEqual(finalState, .applied)
    }

    func testWithdrawTombstones() async {
        let store = InMemoryProposalStore()
        let p = await store.enqueue(makeProposal())
        let withdrew = await store.withdraw(p.id)
        XCTAssertTrue(withdrew)
        let state = await store.state(p.id)
        XCTAssertEqual(state, .withdrawn)
        let list = await store.list(origin: nil)
        XCTAssertTrue(list.isEmpty)
    }

    func testStateUnknownForNeverSeen() async {
        let store = InMemoryProposalStore()
        let id = UUID()
        let state = await store.state(id)
        XCTAssertEqual(state, .unknown)
    }

    func testResolveTwiceIsNoOp() async {
        let store = InMemoryProposalStore()
        let p = await store.enqueue(makeProposal())
        let firstApplied = await store.markApplied(p.id, by: .person)
        XCTAssertTrue(firstApplied)
        let secondApplied = await store.markApplied(p.id, by: .person)
        XCTAssertFalse(secondApplied)
    }

    func testFailedApplyStaysPendingAndIsNotRejected() async {
        let store = InMemoryProposalStore()
        let p = await store.enqueue(makeProposal())
        let marked = await store.markApplyFailed(p.id, reason: nil)
        XCTAssertTrue(marked)
        let state = await store.state(p.id)
        XCTAssertEqual(state, .failed)
        let list = await store.list(origin: nil)
        XCTAssertEqual(list.map(\.id), [p.id], "failed apply must remain in the strip for retry")
        let applied = await store.markApplied(p.id, by: .person)
        XCTAssertTrue(applied)
        let after = await store.state(p.id)
        XCTAssertEqual(after, .applied)
    }

    /// Plan 17 A4 (QA N7): a failed apply keeps its reason — across a
    /// restart — until the next attempt or the proposal's resolution.
    func testAFailedApplyKeepsItsReason() async {
        let persistence = DiskPersistence<ProposalJournal>(
            subdirectory: "VerbinalProposalJournalTests-\(UUID().uuidString)", fileName: "journal.json",
            logger: Logger(subsystem: "com.codebg.Verbinal.tests", category: "ProposalJournal"))
        let store = InMemoryProposalStore(journal: persistence)
        let p = await store.enqueue(makeProposal())
        _ = await store.markApplyFailed(p.id, reason: "HTTP 403: quota exceeded")
        let reason = await store.failureReason(p.id)
        XCTAssertEqual(reason, "HTTP 403: quota exceeded")

        let restarted = InMemoryProposalStore(journal: persistence)
        let kept = await restarted.failureReason(p.id)
        XCTAssertEqual(kept, "HTTP 403: quota exceeded")
        _ = await restarted.beginApply(p.id)
        let retrying = await restarted.failureReason(p.id)
        XCTAssertNil(retrying, "a new attempt is not the old failure")
        _ = await restarted.markApplyFailed(p.id, reason: "again")
        _ = await restarted.withdraw(p.id)
        let gone = await restarted.failureReason(p.id)
        XCTAssertNil(gone)
    }

    /// Plan 19 S4 (QA N7): an apply running says since when; one the app
    /// quit during comes back failed, saying so, not plain pending.
    func testAnApplyCutShortByAQuitFailsAndSaysWhy() async {
        let persistence = DiskPersistence<ProposalJournal>(
            subdirectory: "VerbinalProposalJournalTests-\(UUID().uuidString)", fileName: "journal.json",
            logger: Logger(subsystem: "com.codebg.Verbinal.tests", category: "ProposalJournal"))
        let start = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryProposalStore(journal: persistence, now: { start })
        let p = await store.enqueue(makeProposal())
        _ = await store.beginApply(p.id)
        let since = await store.applyingSince(p.id)
        XCTAssertEqual(since, start)
        let state = await store.state(p.id)
        XCTAssertEqual(state, .applying)

        let relaunched = InMemoryProposalStore(journal: persistence, now: { start })
        let after = await relaunched.state(p.id)
        XCTAssertEqual(after, .failed)
        let reason = await relaunched.failureReason(p.id)
        XCTAssertEqual(reason, InMemoryProposalStore.interruptedReason)
        let sinceAfter = await relaunched.applyingSince(p.id)
        XCTAssertNil(sinceAfter)

        _ = await relaunched.beginApply(p.id)
        _ = await relaunched.markApplied(p.id, by: .person)
        let third = InMemoryProposalStore(journal: persistence, now: { start })
        let resolved = await third.state(p.id)
        XCTAssertEqual(resolved, .applied, "a finished apply is not taken for an interrupted one")
    }

    /// Plan 21 N5: "get_proposal_state forgets failed proposals after ~5 min
    /// though the item stays in Pending" — it does not: a pending proposal's
    /// state is read from the queue, not a tombstone, until it expires.
    func testAFailedProposalStillPendingIsNotForgottenAfterFiveMinutes() async {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 2_000_000) }
        let clock = Clock()
        let store = InMemoryProposalStore(now: { clock.now })
        let p = await store.enqueue(makeProposal())
        _ = await store.beginApply(p.id)
        _ = await store.markApplyFailed(p.id, reason: "no such session x")
        clock.now = clock.now.addingTimeInterval(30 * 60)
        let state = await store.state(p.id)
        XCTAssertEqual(state, .failed)
        let reason = await store.failureReason(p.id)
        XCTAssertEqual(reason, "no such session x")
    }

    /// Plan 17 A4 (QA N7): a withdrawn proposal gives its slot back.
    func testReleasingGivesASlotBack() async {
        let budget = ProposalBudget(limit: 2)
        let origin = OperationOrigin.external(clientID: "c")
        _ = await budget.tryAccept(origin: origin)
        _ = await budget.tryAccept(origin: origin)
        var remaining = await budget.remaining(for: origin)
        XCTAssertEqual(remaining, 0)
        await budget.release(origin: origin)
        remaining = await budget.remaining(for: origin)
        XCTAssertEqual(remaining, 1)
        await budget.release(origin: origin)
        await budget.release(origin: origin)
        remaining = await budget.remaining(for: origin)
        XCTAssertEqual(remaining, 2, "never more than the limit")
    }

    func testJournalRehydratesPendingUnderOriginalIDs() async {
        let logger = Logger(subsystem: "com.codebg.Verbinal.tests", category: "ProposalJournal")
        let persistence = DiskPersistence<ProposalJournal>(
            subdirectory: "VerbinalProposalJournalTests-\(UUID().uuidString)",
            fileName: "journal.json",
            logger: logger
        )
        let originalID = UUID()
        let first = InMemoryProposalStore(journal: persistence)
        _ = await first.enqueue(PendingProposal(
            id: originalID,
            toolName: "tool",
            kind: "kind",
            summary: "summary",
            payload: Data(#"{"x":1}"#.utf8),
            origin: .external(clientID: "c")
        ))
        _ = await first.markRejected(UUID()) // no-op, different id
        let second = InMemoryProposalStore(journal: persistence)
        let restored = await second.list(origin: nil)
        XCTAssertEqual(restored.map(\.id), [originalID])
        XCTAssertEqual(restored.first?.summary, "summary")
        let state = await second.state(originalID)
        XCTAssertEqual(state, .pending)
    }

    func testJournalTombstoneSurvivesRelaunch() async {
        let logger = Logger(subsystem: "com.codebg.Verbinal.tests", category: "ProposalJournal")
        let persistence = DiskPersistence<ProposalJournal>(
            subdirectory: "VerbinalProposalJournalTests-\(UUID().uuidString)",
            fileName: "journal.json",
            logger: logger
        )
        let first = InMemoryProposalStore(journal: persistence)
        let p = await first.enqueue(makeProposal())
        _ = await first.markApplied(p.id, by: .person)
        let second = InMemoryProposalStore(journal: persistence)
        let state = await second.state(p.id)
        XCTAssertEqual(state, .applied)
        let appliedAgain = await second.markApplied(p.id, by: .person)
        XCTAssertFalse(appliedAgain, "resolved id must not apply twice after relaunch")
        let pending = await second.list(origin: nil)
        XCTAssertTrue(pending.isEmpty)
    }
}

// MARK: - Bridge integration tests

final class MCPBridgeServiceTests: XCTestCase {

    func testInitializeThenToolsListRoundTrip() async throws {
        let router = AIToolRouter(tools: [EchoReadTool()], auditSink: CapturingAuditSink())
        let identity = MCPBridgeService.ServerIdentity(
            name: "Verbinal",
            version: "1.0.0",
            instructions: "Use describe_app for orientation."
        )
        let bridge = MCPBridgeService(
            router: router, identity: identity,
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8)),
            approval: .allowAll
        )

        let (clientSide, serverSide) = InMemoryTransport.pair()

        // Spin the server side.
        let serveTask = Task { await bridge.serve(on: serverSide) }

        // initialize
        let initParams = InitializeParams(
            protocolVersion: "2024-11-05",
            clientInfo: ClientInfo(name: "test", version: "1.0")
        )
        try await clientSide.send(makeRPC(method: "initialize", id: .int(1), params: initParams))
        let initResp = try await readResponse(from: clientSide)
        XCTAssertEqual(initResp.id, .int(1))
        XCTAssertNotNil(initResp.result)
        XCTAssertNil(initResp.error)

        // tools/list
        try await clientSide.send(makeRPC(method: "tools/list", id: .int(2), params: EmptyArgs()))
        let listResp = try await readResponse(from: clientSide)
        let listBytes = try XCTUnwrap(listResp.result)
        let parsed = try JSONDecoder().decode(ListToolsResult.self, from: listBytes)
        XCTAssertEqual(parsed.tools.map(\.name), ["echo"])

        // tools/call
        try await clientSide.send(makeRPC(method: "tools/call", id: .int(3),
                                          params: CallToolParams(name: "echo",
                                                                 arguments: .object(["k": .string("v")]))))
        let callResp = try await readResponse(from: clientSide)
        let callBytes = try XCTUnwrap(callResp.result)
        let callResult = try JSONDecoder().decode(CallToolResult.self, from: callBytes)
        XCTAssertEqual(callResult.content.count, 1)
        if case .text(let body) = callResult.content[0] {
            // Echoes the JSON arguments back.
            XCTAssertTrue(body.contains("\"k\":\"v\""), "got \(body)")
        } else {
            XCTFail("expected text content")
        }

        // method not found
        try await clientSide.send(makeRPC(method: "no/such", id: .int(4), params: EmptyArgs()))
        let notFound = try await readResponse(from: clientSide)
        XCTAssertEqual(notFound.error?.code, JSONRPCErrorCode.methodNotFound)

        await serverSide.close()
        await clientSide.close()
        _ = await serveTask.value
    }

    /// Plan 23 L2: the recorder hears the session open at `initialize`,
    /// each call begin and end with what it took, and the session close.
    func testTheRecorderHearsTheWholeSession() async throws {
        actor Heard: AgentSessionRecorder {
            var events: [String] = []
            var session: UUID?
            func opened(_ session: UUID, client: String) { self.session = session; events.append("opened \(client)") }
            func callBegan(_ session: UUID, call: UUID, tool: String) { events.append("began \(tool)") }
            func callEnded(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) -> Int? {
                events.append("ended \(tool) \(traced.result.isFailure ? "failed" : "ok")")
                return nil
            }
            func closed(_ session: UUID) { events.append("closed") }
        }
        let heard = Heard()
        let router = AIToolRouter(tools: [EchoReadTool()], auditSink: CapturingAuditSink())
        let bridge = MCPBridgeService(
            router: router, identity: MCPBridgeService.ServerIdentity(name: "X", version: "1"),
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8), recorder: heard))
        let (clientSide, serverSide) = InMemoryTransport.pair()
        let serveTask = Task { await bridge.serve(on: serverSide) }
        try await clientSide.send(makeRPC(method: "initialize", id: .int(1),
                                          params: InitializeParams(protocolVersion: "2024-11-05",
                                                                   clientInfo: ClientInfo(name: "test", version: "1.0"))))
        _ = try await readResponse(from: clientSide)
        try await clientSide.send(makeRPC(method: "tools/call", id: .int(2),
                                          params: CallToolParams(name: "echo", arguments: .object(["k": .string("v")]))))
        _ = try await readResponse(from: clientSide)
        await serverSide.close()
        await clientSide.close()
        _ = await serveTask.value
        let events = await heard.events
        XCTAssertEqual(events, ["opened test/1.0", "began echo", "ended echo ok", "closed"])
        let session = await heard.session
        XCTAssertEqual(session, bridge.session)
    }

    /// Plan 23 L5: a reply that asked CADC or CANFAR, took a while or failed
    /// carries its timing in its own block; the reply's own is untouched.
    func testAReplyCarriesItsTimingWhenItAskedAService() async throws {
        struct AskingTool: JSONReadTool {
            struct Args: Decodable, Sendable { var status: Int }
            struct Output: Encodable, Sendable { let answered: Bool }
            let definition = AIToolDefinition.withStaticSchema(
                name: "ask_archive", description: "Asks the archive.",
                schema: #"{"type":"object","required":["status"],"properties":{"status":{"type":"integer"}},"additionalProperties":false}"#)
            func handle(_ args: Args, context: AIToolContext) async throws -> Output {
                let request = URLRequest(url: URL(string: "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync")!, timeoutInterval: 120)
                _ = try await RequestLedger().send(request) { request in
                    (Data(), HTTPURLResponse(url: request.url!, statusCode: args.status, httpVersion: nil, headerFields: nil)!)
                }
                if args.status >= 400 { throw ToolFailureReason.backendError("the archive said \(args.status)") }
                return Output(answered: true)
            }
        }
        let router = AIToolRouter(tools: [AskingTool(), EchoReadTool()], auditSink: CapturingAuditSink())
        let bridge = MCPBridgeService(router: router, identity: MCPBridgeService.ServerIdentity(name: "X", version: "1"),
                                      services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8)))
        let (clientSide, serverSide) = InMemoryTransport.pair()
        let serveTask = Task { await bridge.serve(on: serverSide) }
        try await clientSide.send(makeRPC(method: "initialize", id: .int(1),
                                          params: InitializeParams(protocolVersion: "2024-11-05",
                                                                   clientInfo: ClientInfo(name: "test", version: "1.0"))))
        _ = try await readResponse(from: clientSide)
        func call(_ id: Int, _ name: String, _ args: JSONValue) async throws -> CallToolResult {
            try await clientSide.send(makeRPC(method: "tools/call", id: .int(id), params: CallToolParams(name: name, arguments: args)))
            let response = try await readResponse(from: clientSide)
            return try JSONDecoder().decode(CallToolResult.self, from: try XCTUnwrap(response.result))
        }
        func texts(_ result: CallToolResult) -> [String] {
            result.content.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
        }

        let answered = texts(try await call(2, "ask_archive", .object(["status": .int(200)])))
        XCTAssertEqual(answered.count, 2)
        XCTAssertEqual(answered[0], #"{"answered":true}"#, "the reply's own block, as it was")
        XCTAssertTrue(answered[1].hasPrefix(#"{"timing":"#), answered[1])
        XCTAssertTrue(answered[1].contains(#""service":"cadc-tap""#), answered[1])
        XCTAssertTrue(answered[1].contains("the CADC archive search answered in"), answered[1])

        let failed = try await call(3, "ask_archive", .object(["status": .int(503)]))
        XCTAssertEqual(failed.isError, true)
        let failedTexts = texts(failed)
        XCTAssertEqual(failedTexts.count, 2)
        XCTAssertTrue(failedTexts[1].contains("is busy and asked to be asked later"), failedTexts[1])
        XCTAssertTrue(failedTexts[1].contains(#""retry":"later""#), failedTexts[1])

        let quick = texts(try await call(4, "echo", .object(["k": .string("v")])))
        XCTAssertEqual(quick.count, 1, "a quick local answer is left as it is")

        await serverSide.close()
        await clientSide.close()
        _ = await serveTask.value
    }

    func testCallBeforeInitializeFails() async throws {
        let router = AIToolRouter(tools: [EchoReadTool()], auditSink: CapturingAuditSink())
        let identity = MCPBridgeService.ServerIdentity(name: "X", version: "1")
        let bridge = MCPBridgeService(
            router: router, identity: identity,
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8))
        )

        let (clientSide, serverSide) = InMemoryTransport.pair()
        let serveTask = Task { await bridge.serve(on: serverSide) }
        try await clientSide.send(makeRPC(method: "tools/list", id: .int(1), params: EmptyArgs()))
        let resp = try await readResponse(from: clientSide)
        XCTAssertEqual(resp.error?.code, JSONRPCErrorCode.serverNotInitialized)
        await serverSide.close()
        await clientSide.close()
        _ = await serveTask.value
    }

    func testAIGuideResolverOverridesDescriptionsAndAddsGuideTools() async throws {
        let router = AIToolRouter(tools: [EchoReadTool()], auditSink: CapturingAuditSink())
        let identity = MCPBridgeService.ServerIdentity(name: "Verbinal", version: "1.0.0")

        let guideTool = AIToolDefinition.withStaticSchema(
            name: "batch_strategy",
            description: "How this user prefers bulk downloads.",
            schema: #"{"type":"object","properties":{}}"#
        )
        let resolver = AIGuideResolver(
            adjustments: {
                AIGuideResolver.Adjustments(
                    descriptionOverrides: ["echo": "Re-tuned echo description."],
                    guideTools: [guideTool]
                )
            },
            guideBody: { name in name == "batch_strategy" ? "Step 1: stage. Step 2: pull." : nil }
        )

        let bridge = MCPBridgeService(
            router: router, identity: identity,
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8)),
            approval: .allowAll,
            aiGuide: resolver
        )

        let (clientSide, serverSide) = InMemoryTransport.pair()
        let serveTask = Task { await bridge.serve(on: serverSide) }

        let initParams = InitializeParams(protocolVersion: "2024-11-05",
                                          clientInfo: ClientInfo(name: "test", version: "1.0"))
        try await clientSide.send(makeRPC(method: "initialize", id: .int(1), params: initParams))
        _ = try await readResponse(from: clientSide)

        // tools/list — override replaces the built-in description; guide appended.
        try await clientSide.send(makeRPC(method: "tools/list", id: .int(2), params: EmptyArgs()))
        let listResp = try await readResponse(from: clientSide)
        let parsed = try JSONDecoder().decode(ListToolsResult.self, from: try XCTUnwrap(listResp.result))
        XCTAssertEqual(parsed.tools.map(\.name), ["echo", "batch_strategy"])
        let echo = try XCTUnwrap(parsed.tools.first { $0.name == "echo" })
        XCTAssertEqual(echo.description, "Re-tuned echo description.",
                       "override must replace the built-in description in tools/list")
        let guide = try XCTUnwrap(parsed.tools.first { $0.name == "batch_strategy" })
        XCTAssertEqual(guide.description, "How this user prefers bulk downloads.")

        // tools/call on the guide tool — returns the stored body, no router dispatch.
        try await clientSide.send(makeRPC(method: "tools/call", id: .int(3),
                                          params: CallToolParams(name: "batch_strategy", arguments: nil)))
        let callResp = try await readResponse(from: clientSide)
        let callResult = try JSONDecoder().decode(CallToolResult.self, from: try XCTUnwrap(callResp.result))
        XCTAssertEqual(callResult.isError, false)
        XCTAssertEqual(callResult.content.count, 1)
        if case .text(let body) = callResult.content[0] {
            XCTAssertEqual(body, "Step 1: stage. Step 2: pull.")
        } else {
            XCTFail("expected text content for guide call")
        }

        // tools/call on a real tool still dispatches to the router.
        try await clientSide.send(makeRPC(method: "tools/call", id: .int(4),
                                          params: CallToolParams(name: "echo", arguments: .object(["k": .string("v")]))))
        let echoResp = try await readResponse(from: clientSide)
        let echoResult = try JSONDecoder().decode(CallToolResult.self, from: try XCTUnwrap(echoResp.result))
        if case .text(let echoBody) = echoResult.content[0] {
            XCTAssertTrue(echoBody.contains("\"k\":\"v\""), "got \(echoBody)")
        } else {
            XCTFail("expected echoed args")
        }

        await serverSide.close()
        await clientSide.close()
        _ = await serveTask.value
    }

    /// Every proposing tool's description ends with the app's own apply
    /// rule — after any AI Guide override — and read tools carry none.
    func testToolsListEndsProposingToolsWithTheApplyRule() async throws {
        let router = AIToolRouter(tools: [EchoReadTool(), WriteSentinelTool()], auditSink: CapturingAuditSink())
        let resolver = AIGuideResolver(
            adjustments: {
                AIGuideResolver.Adjustments(
                    descriptionOverrides: ["write_sentinel": "User wording."], guideTools: [])
            },
            guideBody: { _ in nil })
        let bridge = MCPBridgeService(
            router: router, identity: .init(name: "Verbinal", version: "1.0.0"),
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8)),
            approval: .allowAll, aiGuide: resolver)
        let (clientSide, serverSide) = InMemoryTransport.pair()
        let serveTask = Task { await bridge.serve(on: serverSide) }
        try await clientSide.send(makeRPC(method: "initialize", id: .int(1), params: InitializeParams(
            protocolVersion: "2025-06-18", clientInfo: ClientInfo(name: "test", version: "1.0"))))
        _ = try await readResponse(from: clientSide)

        try await clientSide.send(makeRPC(method: "tools/list", id: .int(2), params: EmptyArgs()))
        let response = try await readResponse(from: clientSide)
        let list = try JSONDecoder().decode(ListToolsResult.self, from: try XCTUnwrap(response.result))
        let write = try XCTUnwrap(list.tools.first { $0.name == "write_sentinel" })
        let rule = try XCTUnwrap(AutoApplyPolicy.toolSentence(for: .semanticWrite))
        XCTAssertEqual(write.description, "User wording. " + rule)
        XCTAssertEqual(list.tools.first { $0.name == "echo" }?.description, "Returns its arguments verbatim")

        await serverSide.close()
        await clientSide.close()
        _ = await serveTask.value
    }

    func testDestructiveChangesNeverApplyWithoutTheUser() {
        XCTAssertFalse(AutoApplyPolicy.appliesAtOnce(.destructive, autoApplyOn: true))
        XCTAssertTrue(AutoApplyPolicy.appliesAtOnce(.semanticWrite, autoApplyOn: true))
        XCTAssertFalse(AutoApplyPolicy.appliesAtOnce(.semanticWrite, autoApplyOn: false))
        XCTAssertNil(AutoApplyPolicy.toolSentence(for: .read))
        XCTAssertTrue(AutoApplyPolicy.toolSentence(for: .destructive)?.contains("always waits") ?? false)
    }

    /// Plan 15 S1 (QA H6): an instruction every later agent reads is the
    /// person's to approve, whatever auto-apply says.
    func testStandingInstructionsNeverApplyWithoutTheUser() {
        XCTAssertFalse(AutoApplyPolicy.appliesAtOnce(.standingInstruction, autoApplyOn: true))
        XCTAssertTrue(AutoApplyPolicy.toolSentence(for: .standingInstruction)?.contains("always waits") ?? false)
        XCTAssertEqual(AIToolRouter.dispatchCeiling(for: .standingInstruction), AIToolRouter.dispatchCeiling(for: .semanticWrite))
    }

    func testAutoAppliedAckMergesExtraEnvelopeAndPayloadId() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["id": "payload-uuid"])
        let proposal = PendingProposal(
            toolName: "save_query",
            kind: "save_query",
            summary: "Save query",
            payload: payload,
            origin: .external(clientID: "test")
        )
        let extra = try JSONEncoder().encode(
            AutoAppliedAck.Extra(
                succeeded: ["ok-1"],
                failed: [.init(id: "ivo://x", error: "timeout")]
            )
        )
        let ack = AutoAppliedAck(proposal: proposal, extraJSON: extra)
        XCTAssertEqual(ack.id, "payload-uuid")
        XCTAssertEqual(ack.succeeded, ["ok-1"])
        XCTAssertEqual(ack.failed, [.init(id: "ivo://x", error: "timeout")])

        let withNote = try JSONEncoder().encode(AutoAppliedAck.Extra(note: "poll list_vospace_path"))
        XCTAssertEqual(AutoAppliedAck(proposal: proposal, extraJSON: withNote).note, "poll list_vospace_path")
        let withFile = try JSONEncoder().encode(AutoAppliedAck.Extra(file: "/Users/u/Downloads/fig.pdf"))
        let fileAck = AutoAppliedAck(proposal: proposal, extraJSON: withFile)
        XCTAssertEqual(fileAck.file, "/Users/u/Downloads/fig.pdf", "a figure export says what it wrote (QA N8)")
        XCTAssertEqual(try JSONDecoder().decode(AutoAppliedAck.self, from: JSONEncoder().encode(fileAck)).file,
                       "/Users/u/Downloads/fig.pdf")

        let extraWins = try JSONEncoder().encode(AutoAppliedAck.Extra(id: "extra-uuid"))
        XCTAssertEqual(AutoAppliedAck(proposal: proposal, extraJSON: extraWins).id, "extra-uuid")

        // Plan 30 N3: a write that found nothing to do says so, and what was there.
        let noOp = AutoAppliedAck(proposal: proposal, extraJSON: try JSONEncoder().encode(
            AutoAppliedAck.Extra.unchanged(id: "r1", "already in Research — left as it was")))
        XCTAssertEqual(noOp.changed, false)
        XCTAssertEqual(noOp.note, "already in Research — left as it was")
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(noOp)) as? [String: Any]
        XCTAssertEqual(wire?["changed"] as? Bool, false)
        let changedWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ack)) as? [String: Any]
        XCTAssertNil(changedWire?["changed"], "absent when it changed something")
    }

    // MARK: - Helpers

    private struct EmptyArgs: Codable {}

    private func makeRPC<P: Encodable>(method: String, id: JSONRPCID, params: P) throws -> Data {
        // Compose a JSON-RPC envelope with the typed params. We do this
        // by hand because JSONRPCRequest's params is Data?.
        let paramBytes = try JSONEncoder().encode(params)
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "method": method,
            "params": try JSONSerialization.jsonObject(with: paramBytes)
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    private func readResponse(from t: InMemoryTransport) async throws -> JSONRPCResponse {
        var iterator = t.incoming.makeAsyncIterator()
        guard let frame = try await iterator.next() else {
            // Stream finished without yielding a response frame — surface as
            // a transport-closed sentinel so the caller's `try` propagates.
            throw MCPTransportError.closed
        }
        return try JSONDecoder().decode(JSONRPCResponse.self, from: frame)
    }
}

private extension JSONRPCID {
    var jsonValue: Any {
        switch self {
        case .int(let i): return i
        case .string(let s): return s
        case .null: return NSNull()
        }
    }
}
