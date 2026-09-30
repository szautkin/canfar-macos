// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import XCTest
@testable import VerbinalKit

/// Plan 25 V: Verbinal speaks every MCP version — the legacy `initialize`
/// handshake, and 2026-07-28's stateless requests with `server/discover`.
final class MCPEraTests: XCTestCase {

    private struct Echo: AITool {
        static let verbClass: VerbClass = .read
        static let agentSafe = true
        let definition = AIToolDefinition.withStaticSchema(
            name: "echo", description: "Echoes.", schema: #"{"type":"object","properties":{}}"#)
        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult { .data(Data(#"{"ok":true}"#.utf8)) }
    }

    /// Waits until cancelled; says so.
    private struct Slow: AITool {
        static let verbClass: VerbClass = .read
        static let agentSafe = true
        let cancelled: Flag
        let definition = AIToolDefinition.withStaticSchema(
            name: "slow", description: "Waits.", schema: #"{"type":"object","properties":{}}"#)
        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.set() }
            return .data(Data("{}".utf8))
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private var client: InMemoryTransport!
    private var server: InMemoryTransport!
    private var serving: Task<Void, Never>!
    private var responses: AsyncThrowingStream<Data, Error>.AsyncIterator!

    private func start(_ tools: [any AITool] = [Echo()]) {
        let bridge = MCPBridgeService(
            router: AIToolRouter(tools: tools, auditSink: CapturingAuditSink()),
            identity: .init(name: "Verbinal", version: "1.4.0", instructions: "Call start_session first."),
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8)))
        (client, server) = InMemoryTransport.pair()
        serving = Task { [server] in await bridge.serve(on: server!) }
        responses = client.incoming.makeAsyncIterator()
    }

    override func tearDown() async throws {
        await server?.close()
        await client?.close()
        _ = await serving?.value
        try await super.tearDown()
    }

    private let modernMeta: [String: Any] = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": ["name": "future-client", "version": "9.0"],
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    private func send(_ id: Any?, _ method: String, _ params: [String: Any] = [:]) async throws {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { envelope["id"] = id }
        try await client.send(try JSONSerialization.data(withJSONObject: envelope))
    }

    private func reply() async throws -> [String: Any] {
        let next = try await responses.next()
        let frame = try XCTUnwrap(next)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
    }

    private func result(_ reply: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
    }

    // MARK: - Modern

    func testAModernClientDiscoversWithoutAHandshake() async throws {
        start()
        try await send(1, "server/discover", ["_meta": modernMeta])
        let answer = try await reply()
        let discovered = try result(answer)
        XCTAssertEqual(discovered["resultType"] as? String, "complete")
        XCTAssertEqual((discovered["supportedVersions"] as? [String])?.first, "2026-07-28")
        XCTAssertTrue((discovered["supportedVersions"] as? [String])?.contains("2024-11-05") == true)
        XCTAssertEqual(discovered["instructions"] as? String, "Call start_session first.")
        XCTAssertNotNil(discovered["ttlMs"])
        let meta = try XCTUnwrap(discovered["_meta"] as? [String: Any])
        XCTAssertEqual((meta["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["name"] as? String, "Verbinal")
    }

    func testAModernClientListsAndCallsStatelessly() async throws {
        start()
        try await send(1, "tools/list", ["_meta": modernMeta])
        let listAnswer = try await reply()
        let listed = try result(listAnswer)
        XCTAssertEqual(listed["resultType"] as? String, "complete")
        XCTAssertEqual(listed["cacheScope"] as? String, "private")
        XCTAssertEqual((listed["tools"] as? [[String: Any]])?.first?["name"] as? String, "echo")
        try await send(2, "tools/call", ["_meta": modernMeta, "name": "echo", "arguments": [:]])
        let callAnswer = try await reply()
        let called = try result(callAnswer)
        XCTAssertEqual(called["resultType"] as? String, "complete")
        XCTAssertNotNil(called["content"])
    }

    func testAVersionVerbinalDoesNotSpeakIsRefusedNamingThoseItDoes() async throws {
        start()
        var meta = modernMeta
        meta["io.modelcontextprotocol/protocolVersion"] = "1900-01-01"
        try await send(1, "tools/list", ["_meta": meta])
        let refused = try await reply()
        let error = try XCTUnwrap(refused["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32022)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["requested"] as? String, "1900-01-01")
        XCTAssertEqual((data["supported"] as? [String])?.first, "2026-07-28")
    }

    // MARK: - Legacy

    func testALegacyClientShakesHandsAsBefore() async throws {
        start()
        try await send(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "old", "version": "1"],
                                         "capabilities": [:]])
        let answer = try await reply()
        let initialized = try result(answer)
        XCTAssertEqual(initialized["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(initialized["instructions"] as? String, "Call start_session first.")
        XCTAssertNil(initialized["resultType"], "a legacy answer stays as it was")
        try await send(2, "tools/list")
        let listed = try await reply()
        XCTAssertNil(try result(listed)["resultType"])
    }

    func testAnUnknownLegacyVersionIsAnsweredWithTheNewest() async throws {
        start()
        try await send(1, "initialize", ["protocolVersion": "2025-12-31", "capabilities": [:]])
        let answer = try await reply()
        XCTAssertEqual(try result(answer)["protocolVersion"] as? String, "2025-11-25")
    }

    // MARK: - Cancellation

    /// A client that stops waiting cancels the call, and gets no answer to it.
    func testACancelledCallStopsAndIsNotAnswered() async throws {
        let cancelled = Flag()
        start([Echo(), Slow(cancelled: cancelled)])
        try await send(1, "tools/call", ["_meta": modernMeta, "name": "slow", "arguments": [:]])
        try await Task.sleep(for: .milliseconds(100))
        try await send(nil, "notifications/cancelled", ["requestId": 1, "reason": "the user gave up"])
        try await send(2, "tools/call", ["_meta": modernMeta, "name": "echo", "arguments": [:]])
        let next = try await reply()
        XCTAssertEqual(next["id"] as? Int, 2, "the cancelled call is not answered")
        for _ in 0..<50 where !cancelled.isSet { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cancelled.isSet)
    }
}
