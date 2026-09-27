// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import os
@testable import VerbinalKit
import MCPCore

/// Liveness guarantees for the MCP server after the 2026-07-21 Mac QA
/// wedge (F5): a slow tool must not head-of-line-block other requests on
/// the same connection, the router's hard deadline must fire even when
/// the work ignores cancellation, and retry loops must respect a
/// wall-clock budget.
final class ServerLivenessTests: XCTestCase {

    // MARK: - Stub tools

    /// Read tool that sleeps (cancellation-responsive) before echoing.
    private struct SlowTool: AITool {
        static let verbClass: VerbClass = .read
        static let agentSafe: Bool = true
        let sleepSeconds: Double
        let definition = AIToolDefinition.withStaticSchema(
            name: "slow", description: "sleeps",
            schema: #"{"type":"object","properties":{},"additionalProperties":false}"#)

        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            return .data(Data(#"{"slow":true}"#.utf8))
        }
    }

    private struct FastTool: AITool {
        static let verbClass: VerbClass = .read
        static let agentSafe: Bool = true
        let definition = AIToolDefinition.withStaticSchema(
            name: "fast", description: "returns instantly",
            schema: #"{"type":"object","properties":{},"additionalProperties":false}"#)

        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            .data(Data(#"{"fast":true}"#.utf8))
        }
    }

    /// Read tool that IGNORES cancellation: sleeps in small chunks,
    /// swallowing the cancellation error each time — models a wedged
    /// mmap fault / CPU loop that defeats task-group watchdogs.
    private struct StubbornTool: AITool {
        static let verbClass: VerbClass = .read
        static let agentSafe: Bool = true
        let totalSeconds: Double
        let definition = AIToolDefinition.withStaticSchema(
            name: "stubborn", description: "ignores cancellation",
            schema: #"{"type":"object","properties":{},"additionalProperties":false}"#)

        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            let chunks = max(1, Int(totalSeconds / 0.05))
            for _ in 0..<chunks {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return .data(Data(#"{"finished":true}"#.utf8))
        }
    }

    // MARK: - withHardDeadline

    func testHardDeadlineReturnsDespiteCancellationIgnoringWork() async {
        let started = ContinuousClock.now
        let result = await withHardDeadline(
            seconds: 0.2,
            onDeadline: { "deadline" },
            work: {
                // 3s of cancellation-ignoring work.
                for _ in 0..<60 { try? await Task.sleep(nanoseconds: 50_000_000) }
                return "work"
            })
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(result, "deadline")
        XCTAssertLessThan(elapsed, .seconds(1.5),
                          "caller must resume at the deadline, not when the straggler finishes")
    }

    /// An agent opening a huge file needs an answer in time while the load
    /// itself finishes: the deadline must not cancel that work.
    func testHardDeadlineCanLeaveTheWorkRunning() async throws {
        let finished = OSAllocatedUnfairLock(initialState: false)
        let result = await withHardDeadline(
            seconds: 0.05,
            cancelsWork: false,
            onDeadline: { "still loading" },
            work: {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let cancelled = Task.isCancelled
                finished.withLock { $0 = !cancelled }
                return "loaded"
            })
        XCTAssertEqual(result, "still loading")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(finished.withLock { $0 }, "the work ran to the end, uncancelled")
    }

    func testHardDeadlineReturnsWorkResultWhenFast() async {
        let result = await withHardDeadline(
            seconds: 5,
            onDeadline: { "deadline" },
            work: { "work" })
        XCTAssertEqual(result, "work")
    }

    // MARK: - Router dispatch deadline

    func testRouterDispatchDeadlineFiresForStubbornTool() async throws {
        let sink = CapturingAuditSink()
        let router = AIToolRouter(
            tools: [StubbornTool(totalSeconds: 3)],
            auditSink: sink,
            dispatchCeilingOverride: 0.2)
        let context = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 8))

        let started = ContinuousClock.now
        let result = await router.dispatch(
            name: "stubborn", rawArguments: Data("{}".utf8), context: context)
        let elapsed = ContinuousClock.now - started

        XCTAssertLessThan(elapsed, .seconds(1.5), "dispatch must return at the ceiling")
        guard case .failed(let reason) = result, case .backendError(let message) = reason else {
            return XCTFail("expected backendError, got \(result)")
        }
        XCTAssertTrue(message.contains("dispatch deadline"), "got: \(message)")
        // The deadline emits its own audit entry immediately.
        let tags = sink.snapshot().map(\.outcome)
        XCTAssertTrue(tags.contains(where: {
            if case .failed(let tag) = $0 { return tag == "dispatchDeadline" }
            return false
        }), "expected a dispatchDeadline audit entry, got \(tags)")
    }

    // MARK: - Concurrent serve loop

    /// One connection, a 2s slow call followed by a fast call: the fast
    /// response must come back FIRST. Before the concurrent serve loop
    /// the fast call queued behind the slow one.
    func testSlowToolDoesNotBlockFastToolOnSameConnection() async throws {
        let router = AIToolRouter(
            tools: [SlowTool(sleepSeconds: 2), FastTool()],
            auditSink: CapturingAuditSink())
        let bridge = MCPBridgeService(
            router: router,
            identity: .init(name: "Verbinal", version: "1.0.0"),
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8)),
            approval: .allowAll)

        let (clientSide, serverSide) = InMemoryTransport.pair()
        let serveTask = Task { await bridge.serve(on: serverSide) }

        try await clientSide.send(Self.makeRPC(
            method: "initialize", id: .int(1),
            params: InitializeParams(protocolVersion: "2024-11-05",
                                     clientInfo: ClientInfo(name: "test", version: "1.0"))))

        var iterator = clientSide.incoming.makeAsyncIterator()
        _ = try await iterator.next() // initialize response

        try await clientSide.send(Self.makeRPC(
            method: "tools/call", id: .int(2),
            params: CallToolParams(name: "slow", arguments: nil)))
        try await clientSide.send(Self.makeRPC(
            method: "tools/call", id: .int(3),
            params: CallToolParams(name: "fast", arguments: nil)))

        let firstFrameOpt = try await iterator.next()
        let firstFrame = try XCTUnwrap(firstFrameOpt)
        let first = try JSONDecoder().decode(JSONRPCResponse.self, from: firstFrame)
        XCTAssertEqual(first.id, .int(3),
                       "the fast call must answer before the 2s slow call")

        let secondFrameOpt = try await iterator.next()
        let secondFrame = try XCTUnwrap(secondFrameOpt)
        let second = try JSONDecoder().decode(JSONRPCResponse.self, from: secondFrame)
        XCTAssertEqual(second.id, .int(2))

        await serverSide.close()
        await clientSide.close()
        _ = await serveTask.value
    }

    // MARK: - Retry wall-clock budget

    func testRetryingHonorsOverallBudget() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let attempts = Counter()
        let policy = RetryPolicy(
            maxAttempts: 10,
            initialDelay: .milliseconds(50),
            overallBudget: .milliseconds(60))
        do {
            _ = try await retrying(policy) { () async throws -> Int in
                _ = attempts.bump()
                throw URLError(.timedOut) // transient — would retry forever on attempts alone
            }
            XCTFail("expected the transient error to surface")
        } catch {
            // expected
        }
        XCTAssertLessThanOrEqual(attempts.value, 2,
                                 "wall-clock budget must stop retries long before maxAttempts")
    }

    private static func makeRPC<P: Encodable>(method: String, id: JSONRPCID, params: P) throws -> Data {
        let paramBytes = try JSONEncoder().encode(params)
        let idValue: Any
        switch id {
        case .int(let i): idValue = i
        case .string(let s): idValue = s
        case .null: idValue = NSNull()
        }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idValue,
            "method": method,
            "params": try JSONSerialization.jsonObject(with: paramBytes),
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }
}
