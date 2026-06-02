// SPDX-License-Identifier: MPL-2.0

import XCTest
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
                _ = await store.markApplied(id)
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
            apply: { id in try await counter.bumpAndRecord(id) }
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

    func testAutoApplyHookFailureLeavesProposalInQueue() async {
        let store = InMemoryProposalStore()
        let counter = ApplyCallCounter()
        await counter.setShouldThrow(true)
        let hook = AutoApplyHook(
            shouldAutoApply: { _, _ in true },
            apply: { id in try await counter.bumpAndRecord(id) }
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
        let pending = await store.list(origin: nil)
        XCTAssertEqual(pending.count, 1, "failed auto-apply must leave proposal in queue for manual review")
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
        let applied = await store.markApplied(p.id)
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
        let firstApplied = await store.markApplied(p.id)
        XCTAssertTrue(firstApplied)
        let secondApplied = await store.markApplied(p.id)
        XCTAssertFalse(secondApplied)
    }
}

// MARK: - Bridge integration tests

final class MCPBridgeServiceTests: XCTestCase {

    /// In-process pair of stub transports: anything one side sends, the
    /// other side receives. Used to drive `MCPBridgeService.serve` through
    /// a real-shape JSON-RPC conversation without TCP/sockets.
    private final class PairTransport: MCPTransport, @unchecked Sendable {
        let incoming: AsyncThrowingStream<Data, Error>
        let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
        var peer: PairTransport?
        private let stateLock = NSLock()
        private var closed = false

        init() {
            var c: AsyncThrowingStream<Data, Error>.Continuation!
            self.incoming = AsyncThrowingStream { c = $0 }
            self.inboundContinuation = c
        }

        func send(_ payload: Data) async throws {
            stateLock.lock()
            let isClosed = closed
            stateLock.unlock()
            if isClosed { throw MCPTransportError.closed }
            peer?.inboundContinuation.yield(payload)
        }

        func close() async {
            stateLock.lock()
            guard !closed else { stateLock.unlock(); return }
            closed = true
            stateLock.unlock()
            inboundContinuation.finish()
        }
    }

    private func makePair() -> (PairTransport, PairTransport) {
        let a = PairTransport()
        let b = PairTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }

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

        let (clientSide, serverSide) = makePair()

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

    func testCallBeforeInitializeFails() async throws {
        let router = AIToolRouter(tools: [EchoReadTool()], auditSink: CapturingAuditSink())
        let identity = MCPBridgeService.ServerIdentity(name: "X", version: "1")
        let bridge = MCPBridgeService(
            router: router, identity: identity,
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8))
        )

        let (clientSide, serverSide) = makePair()
        let serveTask = Task { await bridge.serve(on: serverSide) }
        try await clientSide.send(makeRPC(method: "tools/list", id: .int(1), params: EmptyArgs()))
        let resp = try await readResponse(from: clientSide)
        XCTAssertEqual(resp.error?.code, JSONRPCErrorCode.serverNotInitialized)
        await serverSide.close()
        await clientSide.close()
        _ = await serveTask.value
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

    private func readResponse(from t: PairTransport) async throws -> JSONRPCResponse {
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
