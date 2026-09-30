// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import XCTest
@testable import VerbinalKit

/// Plan 25 M: no session, no tools — only `start_session` and
/// `describe_app` work before the person allows one — and every reply
/// names its session.
final class SessionGateTests: XCTestCase {

    private struct Named: AITool {
        static let verbClass: VerbClass = .read
        static let agentSafe = true
        let definition: AIToolDefinition
        init(_ name: String) {
            definition = AIToolDefinition.withStaticSchema(name: name, description: name, schema: #"{"type":"object","properties":{}}"#)
        }
        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult { .data(Data(#"{"ok":true}"#.utf8)) }
    }

    /// A session control that waits longer than any deadline.
    private struct Waits: AITool {
        static let verbClass: VerbClass = .sessionControl
        static let agentSafe = true
        let definition = AIToolDefinition.withStaticSchema(name: "start_session", description: "Waits.",
                                                           schema: #"{"type":"object","properties":{}}"#)
        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            try? await Task.sleep(for: .milliseconds(300))
            return .data(Data(#"{"waited":true}"#.utf8))
        }
    }

    /// Waits for the person until the assistant stops waiting.
    private struct WaitsForThePerson: AITool {
        static let verbClass: VerbClass = .sessionControl
        static let agentSafe = true
        let definition = AIToolDefinition.withStaticSchema(name: "start_session", description: "Waits.",
                                                           schema: #"{"type":"object","properties":{}}"#)
        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return .failed(.sessionRequired)
        }
    }

    private actor Heard: AgentSessionRecorder {
        var events: [String] = []
        func opened(_ session: UUID, client: String) { events.append("opened") }
        func callBegan(_ session: UUID, call: UUID, tool: String) { events.append("began \(tool)") }
        func callEnded(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) -> Int? {
            events.append("ended \(tool)")
            return nil
        }
        func closed(_ session: UUID) { events.append("closed") }
    }

    private actor Gate: AgentSessionGate {
        var open = false
        func isOpen(_ session: UUID) -> Bool { open }
        func allow() { open = true }
    }

    private func call(_ bridge: MCPBridgeService, _ client: InMemoryTransport,
                      _ iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator,
                      _ id: Int, _ tool: String) async throws -> [String: Any] {
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": [:]]]
        try await client.send(try JSONSerialization.data(withJSONObject: frame))
        let next = try await iterator.next()
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(next)) as? [String: Any])
        return try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
    }

    func testNoSessionNoToolsButStartingOneAndLearningHow() async throws {
        let gate = Gate()
        let bridge = MCPBridgeService(
            router: AIToolRouter(tools: [Named("list_sessions"), Named("start_session"), Named("describe_app")],
                                 auditSink: CapturingAuditSink()),
            identity: .init(name: "Verbinal", version: "1.4.0"),
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8), gate: gate))
        let (client, server) = InMemoryTransport.pair()
        let serving = Task { await bridge.serve(on: server) }
        var replies = client.incoming.makeAsyncIterator()
        let hello: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]]
        try await client.send(try JSONSerialization.data(withJSONObject: hello))
        _ = try await replies.next()

        let refused = try await call(bridge, client, &replies, 1, "list_sessions")
        XCTAssertEqual(refused["isError"] as? Bool, true)
        let text = ((refused["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("sessionRequired: No session — call start_session first"), text)
        XCTAssertEqual((refused["_meta"] as? [String: Any])?[AgentSession.metaKey] as? String, bridge.session.uuidString)

        let started = try await call(bridge, client, &replies, 2, "start_session")
        XCTAssertNotEqual(started["isError"] as? Bool, true, "starting a session works without one")
        let described = try await call(bridge, client, &replies, 3, "describe_app")
        XCTAssertNotEqual(described["isError"] as? Bool, true, "so does learning how")

        await gate.allow()
        let allowed = try await call(bridge, client, &replies, 4, "list_sessions")
        XCTAssertNotEqual(allowed["isError"] as? Bool, true)
        XCTAssertEqual((allowed["_meta"] as? [String: Any])?[AgentSession.metaKey] as? String, bridge.session.uuidString,
                       "every reply names its session")

        await server.close()
        await client.close()
        _ = await serving.value
    }

    /// The person's answer is awaited as long as the assistant waits: no
    /// router deadline cuts a session control short.
    func testASessionControlHasNoDeadline() async {
        let router = AIToolRouter(tools: [Waits()], auditSink: CapturingAuditSink(), dispatchCeilingOverride: 0.05)
        let result = await router.dispatch(name: "start_session", rawArguments: Data("{}".utf8), context: AIToolContext(
            origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget()))
        guard case .data(let data) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"waited":true}"#)
    }

    /// An assistant that disconnects while the person is asked: its call
    /// ends — and says so in the log — before its session closes.
    func testADisconnectEndsTheWaitingCallBeforeTheSessionCloses() async throws {
        let heard = Heard()
        let bridge = MCPBridgeService(
            router: AIToolRouter(tools: [WaitsForThePerson()], auditSink: CapturingAuditSink()),
            identity: .init(name: "Verbinal", version: "1.4.0"),
            services: .init(proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 8),
                            recorder: heard, gate: Gate()))
        let (client, server) = InMemoryTransport.pair()
        let serving = Task { await bridge.serve(on: server) }
        var replies = client.incoming.makeAsyncIterator()
        let hello: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]]
        try await client.send(try JSONSerialization.data(withJSONObject: hello))
        _ = try await replies.next()
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                    "params": ["name": "start_session", "arguments": [:]]]
        try await client.send(try JSONSerialization.data(withJSONObject: frame))
        for _ in 0..<200 where !(await heard.events.contains("began start_session")) {
            try await Task.sleep(for: .milliseconds(5))
        }

        await client.close()
        await server.close()
        _ = await serving.value
        let events = await heard.events
        XCTAssertEqual(events, ["opened", "began start_session", "ended start_session", "closed"])
    }
}
