// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import os

/// Connects an `MCPTransport` to an `AIToolRouter`.
///
/// Owns one transport (typically the server-accepted side of a unix
/// socket; the helper holds the client side). Reads JSON-RPC requests off
/// the transport, dispatches to the router, marshals the result back to
/// JSON-RPC, sends it.
///
/// Lifecycle:
///   * Start with `serve(on:transport:approval:)`. Returns when the
///     transport's incoming stream finishes (EOF or error).
///   * Each connection is its own bridge instance; the app owns the
///     listener and creates a fresh service per accepted transport.
///
/// This service implements only the methods needed for a useful agent
/// loop: `initialize`, `tools/list`, `tools/call`. Anything else returns
/// `methodNotFound` per JSON-RPC 2.0.
public actor MCPBridgeService {
    public struct ServerIdentity: Sendable {
        public let name: String
        public let version: String
        public let instructions: String?

        public init(name: String, version: String, instructions: String? = nil) {
            self.name = name
            self.version = version
            self.instructions = instructions
        }
    }

    /// Pluggable approval gate. Returns `true` if the connecting client
    /// is permitted to proceed beyond `initialize`. The app passes
    /// `.allowAll` — the Agents toggle upstream is the gate today.
    public struct ApprovalGate: Sendable {
        public let permit: @Sendable (_ clientID: String, _ clientInfo: ClientInfo?) async -> Bool

        public init(permit: @escaping @Sendable (_ clientID: String, _ clientInfo: ClientInfo?) async -> Bool) {
            self.permit = permit
        }

        public static let allowAll = ApprovalGate { _, _ in true }
    }

    private let router: AIToolRouter
    private let identity: ServerIdentity
    private let approval: ApprovalGate
    /// Per-connection capability bag, injected at construction so the bridge
    /// can never be served in an unconfigured state.
    private let services: PerConnectionServices
    /// Optional AI Guide hook. When set, `tools/list` substitutes user
    /// description overrides + appends user guide tools, and `tools/call`
    /// answers guide-tool calls with stored text. `nil` serves the plain
    /// router manifest.
    private let aiGuide: AIGuideResolver?
    private let logger = Logger(subsystem: "com.codebg.Verbinal.agent", category: "bridge")

    /// Per-connection state. Initialized lazily on the first `initialize`
    /// request — anything before that returns `serverNotInitialized`.
    private var clientID: String?
    private var initialized: Bool = false
    /// This connection's assistant session (plan 23). One bridge serves one
    /// connection, so one session: a relay reconnecting after Verbinal
    /// restarts is a new one.
    public nonisolated let session = UUID()
    /// The MCP version the client speaks: its `initialize`'s, or what its
    /// latest request declared.
    private var mcpVersion: String?

    /// Concurrently-running `tools/call` handlers (see `routeFrame`).
    /// Keyed so completed handlers can remove themselves; drained with
    /// cancellation when the transport closes.
    private var inFlightCalls: [UUID: Task<Void, Never>] = [:]
    /// Each in-flight call's key, by its request id — for
    /// `notifications/cancelled` (plan 25 V).
    private var inFlightByRequest: [JSONRPCID: UUID] = [:]
    /// Calls the client cancelled: no answer is sent for them.
    private var cancelledRequests: Set<JSONRPCID> = []
    /// Cap on concurrent `tools/call` handling per connection. Beyond
    /// this, frames fall back to inline (serial) handling — natural
    /// backpressure instead of unbounded task growth.
    private static let maxConcurrentCalls = 8
    /// How long a closing connection waits for its cancelled calls to say
    /// how they ended — "stopped waiting" — before its session closes.
    private static let closingGrace: TimeInterval = 2

    public init(
        router: AIToolRouter,
        identity: ServerIdentity,
        services: PerConnectionServices,
        approval: ApprovalGate = .allowAll,
        aiGuide: AIGuideResolver? = nil
    ) {
        self.router = router
        self.identity = identity
        self.services = services
        self.approval = approval
        self.aiGuide = aiGuide
    }

    /// Drive the connection. Returns when the transport closes.
    public func serve(on transport: any MCPTransport) async {
        logger.info("connection opened")
        defer { logger.info("connection closed") }
        do {
            for try await frame in transport.incoming {
                if frame.isEmpty { continue } // skip ndjson keep-alives
                await routeFrame(frame, transport: transport)
            }
        } catch {
            logger.notice("transport ended: \(String(describing: error), privacy: .public)")
        }
        let stopping = cancelInFlightCalls()
        _ = await withHardDeadline(seconds: Self.closingGrace, cancelsWork: false, onDeadline: {}) {
            for call in stopping { await call.value }
        }
        if initialized { await services.recorder?.closed(session) }
    }

    /// Route one frame: `tools/call` runs in its OWN task so a slow tool
    /// can never head-of-line-block the next request on this connection
    /// (the 2026-07-21 Mac QA wedge: one stalled search queued every
    /// later call — including `get_current_view` — into the client's
    /// 4-minute timeout). Out-of-order JSON-RPC responses are legal
    /// (matched by id) and the transport contract guarantees concurrent
    /// `send` calls don't interleave frame bytes. Lifecycle methods
    /// (`initialize`, `tools/list`, …) stay inline: they're cheap and
    /// order-sensitive.
    private func routeFrame(_ frame: Data, transport: any MCPTransport) async {
        let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
        let method = object?["method"] as? String
        if method == "notifications/cancelled" {
            cancel(object?["params"] as? [String: Any])
            return
        }
        guard method == "tools/call", inFlightCalls.count < Self.maxConcurrentCalls else {
            await handleIncoming(frame: frame, transport: transport)
            return
        }
        let key = UUID()
        let requestID = (try? JSONDecoder().decode(JSONRPCRequest.self, from: frame))?.id
        if let requestID { inFlightByRequest[requestID] = key }
        inFlightCalls[key] = Task { [weak self] in
            guard let self else { return }
            await self.handleIncoming(frame: frame, transport: transport)
            await self.finishInFlightCall(key, requestID: requestID)
        }
    }

    private func finishInFlightCall(_ key: UUID, requestID: JSONRPCID?) {
        inFlightCalls[key] = nil
        if let requestID {
            inFlightByRequest[requestID] = nil
            cancelledRequests.remove(requestID)
        }
    }

    /// The client stopped waiting for a request: the call is cancelled —
    /// an approval window closes with it — and no answer is sent.
    private func cancel(_ params: [String: Any]?) {
        let raw = params?["requestId"]
        let id: JSONRPCID? = (raw as? Int).map(JSONRPCID.int) ?? (raw as? String).map(JSONRPCID.string)
        guard let id, let key = inFlightByRequest[id] else { return }
        logger.info("call cancelled by the client")
        cancelledRequests.insert(id)
        inFlightCalls[key]?.cancel()
    }

    private func cancelInFlightCalls() -> [Task<Void, Never>] {
        let calls = Array(inFlightCalls.values)
        for task in calls { task.cancel() }
        inFlightCalls.removeAll()
        return calls
    }

    // MARK: - Dispatch

    private func handleIncoming(frame: Data, transport: any MCPTransport) async {
        // Distinguish notifications from requests *before* typed decoding.
        // JSON-RPC notifications omit `id` entirely; per the spec, the
        // server MUST NOT reply to them. Our typed decoder defaults a
        // missing `id` to `.null`, which the MCP schema validators
        // (Zod-based on the Cowork side) then reject — id can be string
        // or number, but never null. So peek at the parsed object first
        // and bail silently on notifications.
        let parsed = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
        let methodForLog = (parsed?["method"] as? String) ?? "<unknown>"
        let idForLog: String = {
            switch parsed?["id"] {
            case let n as Int:    return String(n)
            case let n as Int64:  return String(n)
            case let s as String: return "\"\(s)\""
            case is NSNull:       return "null"
            default:              return "<absent>"
            }
        }()
        let isNotification = parsed?["id"] == nil

        logger.debug("recv \(methodForLog, privacy: .public) id=\(idForLog, privacy: .public) (\(frame.count) bytes)")

        if isNotification {
            logger.debug("ignoring notification \(methodForLog, privacy: .public) (no id)")
            return
        }

        let decoder = JSONDecoder()
        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: frame)
        } catch {
            // Malformed request with an id we couldn't parse — drop.
            logger.notice("dropped malformed frame: \(error.localizedDescription, privacy: .public)")
            return
        }

        // A modern request declares its version in `_meta`: one Verbinal
        // does not speak is refused, naming those it does (plan 25 V).
        let declared = MCPProtocol.declaredVersion(in: request.params)
        if let declared, !MCPProtocol.supported.contains(declared) {
            await send(MCPProtocol.unsupported(id: request.id, requested: declared), transport: transport, method: methodForLog)
            return
        }
        if let declared { mcpVersion = declared }
        if declared != nil, request.method != "server/discover" { await openStatelessClient(request) }

        var response: JSONRPCResponse
        switch request.method {
        case "server/discover":
            response = successResponse(id: request.id, body: DiscoverResult(
                capabilities: ServerCapabilities(tools: .init(listChanged: nil)),
                instructions: identity.instructions))
        case "initialize":
            response = await handleInitialize(request)
        case "tools/list":
            response = await handleToolsList(request)
        case "tools/call":
            response = await handleToolsCall(request)
        case "resources/list":
            response = handleResourcesList(request)
        case "resources/read":
            response = handleResourcesRead(request)
        case "logging/setLevel":
            // Acknowledge but do nothing — our os.log subsystem is the
            // authoritative log surface, and Cowork doesn't drive it.
            response = successResponse(id: request.id, body: EmptyObject())
        case "ping":
            response = successResponse(id: request.id, body: EmptyObject())
        default:
            logger.notice("method not found: \(request.method, privacy: .public)")
            response = .failure(
                id: request.id,
                error: JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "method not found: \(request.method)"
                )
            )
        }

        // A cancelled request gets no answer.
        if cancelledRequests.contains(request.id) { return }
        // A modern request's result carries its type and Verbinal's identity.
        if declared != nil || request.method == "server/discover", let result = response.result {
            let isList = ["tools/list", "resources/list", "server/discover"].contains(request.method)
            response = .success(id: request.id, result: MCPProtocol.modernized(
                result, server: ServerInfo(name: identity.name, version: identity.version), isList: isList))
        }
        await send(response, transport: transport, method: methodForLog)
    }

    private func send(_ response: JSONRPCResponse, transport: any MCPTransport, method: String) async {
        do {
            let bytes = try JSONEncoder().encode(response)
            try await transport.send(bytes)
            let outcome = response.error != nil ? "error" : "ok"
            logger.debug("send \(method, privacy: .public) (\(bytes.count) bytes, \(outcome, privacy: .public))")
        } catch {
            logger.error("send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A modern client has no handshake: its first request opens the
    /// connection's session, with the identity it declares (plan 25 V).
    private func openStatelessClient(_ request: JSONRPCRequest) async {
        guard !initialized else { return }
        let info = MCPProtocol.declaredClient(in: request.params)
        clientID = info.map { "\($0.name)/\($0.version)" } ?? "unnamed client"
        initialized = true
        logger.info("stateless client=\(self.clientID ?? "", privacy: .public)")
        await services.recorder?.opened(session, client: clientID ?? "unnamed client")
    }

    // MARK: - initialize

    private func handleInitialize(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let raw = request.params else {
            return .failure(id: request.id, error: invalidParams("missing params"))
        }
        let params: InitializeParams
        do {
            params = try JSONDecoder().decode(InitializeParams.self, from: raw)
        } catch {
            return .failure(id: request.id, error: invalidParams("\(error)"))
        }

        // Stable per-connection client identifier. Falls back to a UUID
        // if the client didn't volunteer a name (rare).
        let cid = params.clientInfo.map { "\($0.name)/\($0.version)" } ?? UUID().uuidString
        logger.info("initialize from \(cid, privacy: .public) protocolVersion=\(params.protocolVersion, privacy: .public)")
        let permitted = await approval.permit(cid, params.clientInfo)
        guard permitted else {
            logger.notice("initialize denied for \(cid, privacy: .public)")
            return .failure(
                id: request.id,
                error: JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.sessionNotApproved,
                    message: "Client not approved by user."
                )
            )
        }

        let reopened = initialized
        self.clientID = cid
        self.mcpVersion = MCPProtocol.negotiated(params.protocolVersion)
        self.initialized = true
        logger.info("initialized client=\(cid, privacy: .public)")
        if !reopened { await services.recorder?.opened(session, client: cid) }

        let result = InitializeResult(
            protocolVersion: MCPProtocol.negotiated(params.protocolVersion),
            capabilities: ServerCapabilities(
                // The bridge (`ResilientBridge`) sends list_changed when it
                // reconnects to a restarted app.
                tools: .init(listChanged: true),
                resources: .init(subscribe: false, listChanged: false),
                logging: .object([:])
            ),
            serverInfo: ServerInfo(name: identity.name, version: identity.version),
            instructions: identity.instructions
        )
        return successResponse(id: request.id, body: result)
    }

    // MARK: - resources/list, resources/read

    /// canfar-mac doesn't expose any MCP resources today (the read tools
    /// already cover the surface). Returning an empty list satisfies
    /// clients that gate registration on a successful `resources/list`
    /// after they see `resources` in the capabilities advertisement.
    private func handleResourcesList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard initialized else { return notInitialized(id: request.id) }
        return successResponse(id: request.id, body: ListResourcesResult(resources: []))
    }

    private func handleResourcesRead(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard initialized else { return notInitialized(id: request.id) }
        // No URI is registered, so any read is invalid.
        return .failure(id: request.id, error: JSONRPCErrorPayload(
            code: JSONRPCErrorCode.invalidParams,
            message: "No resources are exposed by this server."
        ))
    }

    // MARK: - tools/list

    private func handleToolsList(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard initialized else { return notInitialized(id: request.id) }
        let tools = await PublishedManifest.tools(router: router, aiGuide: aiGuide)
        logger.info("tools/list -> \(tools.count) tool\(tools.count == 1 ? "" : "s")")
        return successResponse(id: request.id, body: ListToolsResult(tools: tools))
    }

    // MARK: - tools/call

    private func handleToolsCall(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard initialized, let cid = clientID else {
            return notInitialized(id: request.id)
        }
        guard let raw = request.params else {
            return .failure(id: request.id, error: invalidParams("missing params"))
        }
        let params: CallToolParams
        do {
            params = try JSONDecoder().decode(CallToolParams.self, from: raw)
        } catch {
            return .failure(id: request.id, error: invalidParams("\(error)"))
        }

        // No session, no tools: until the person allows one, only starting
        // it works (plan 25 M). The refusal is a call like any other, logged.
        if let gate = services.gate, !AgentSession.openBeforeSession.contains(params.name), !(await gate.isOpen(session)) {
            logger.notice("tools/call \(params.name, privacy: .public) -> no session")
            let call = UUID()
            await services.recorder?.callBegan(session, call: call, tool: params.name)
            _ = await services.recorder?.callEnded(session, call: call, tool: params.name, traced: AIToolRouter.Traced(
                result: .failed(.sessionRequired), seconds: 0, trace: RequestTrace(parent: nil)))
            return stamped(mapToolResult(id: request.id, result: .failed(.sessionRequired)))
        }

        // AI Guide tools are read-only: a call returns the stored instruction
        // text directly (no execution, no router dispatch). Checked before the
        // router so a guide name can't fall through to `unknownTool`.
        if let aiGuide, let body = await aiGuide.guideBody(params.name) {
            logger.info("tools/call \(params.name, privacy: .public) -> guide (\(body.count) chars)")
            // A guide read is a call too: the session log keeps every one.
            let call = UUID()
            await services.recorder?.callBegan(session, call: call, tool: params.name)
            _ = await services.recorder?.callEnded(session, call: call, tool: params.name, traced: AIToolRouter.Traced(
                result: .data(Data(body.utf8)), seconds: 0, trace: RequestTrace(parent: nil)))
            let payload = CallToolResult(content: [.text(body)], isError: false)
            return stamped(successResponse(id: request.id, body: payload))
        }

        // The router takes raw JSON args (Data). Re-encode the typed
        // arguments. Absent arguments encode as a JSON `null`.
        let argBytes: Data
        if let args = params.arguments {
            do {
                argBytes = try JSONEncoder().encode(args)
            } catch {
                return .failure(id: request.id, error: invalidParams("\(error)"))
            }
        } else {
            argBytes = Data("null".utf8)
        }

        // Build the per-call context. Each call gets a fresh requestID.
        let context = AIToolContext(
            origin: .external(clientID: cid),
            requestID: UUID(),
            proposals: services.proposals,
            budget: services.budget,
            eventLog: services.eventLog,
            session: session,
            client: clientID,
            mcpVersion: mcpVersion
        )

        logger.info("tools/call \(params.name, privacy: .public) (\(argBytes.count) bytes args)")
        await services.recorder?.callBegan(session, call: context.requestID, tool: params.name)
        let traced = await router.dispatchTraced(
            name: params.name,
            rawArguments: argBytes,
            context: context
        )
        let token = await services.recorder?.callEnded(session, call: context.requestID, tool: params.name, traced: traced)
        let result = traced.result
        switch result {
        case .data(let bytes):
            logger.info("tools/call \(params.name, privacy: .public) -> data (\(bytes.count) bytes)")
        case .proposed(let proposal):
            logger.info("tools/call \(params.name, privacy: .public) -> proposed kind=\(proposal.kind, privacy: .public) id=\(proposal.id.uuidString, privacy: .public)")
        case .failed(let reason):
            logger.notice("tools/call \(params.name, privacy: .public) -> failed (\(reason.auditTag, privacy: .public))")
        case .image(let data, let mimeType, _):
            logger.info("tools/call \(params.name, privacy: .public) -> image (\(mimeType, privacy: .public), \(data.count) bytes)")
        }
        // What the call took and what it means, when it asked CADC or
        // CANFAR, took a while, or failed (plan 23 L5).
        let note = CallTiming.isWorthNoting(traced)
            ? CallTiming.Note(CallTiming(traced), logToken: token ?? nil, session: session) : nil
        return stamped(mapToolResult(id: request.id, result: result, note: note))
    }

    /// Every reply names its session in `_meta`, so it can be matched to the
    /// session's log (plan 25 S).
    private func stamped(_ response: JSONRPCResponse) -> JSONRPCResponse {
        guard let result = response.result else { return response }
        return .success(id: response.id, result: MCPProtocol.withMeta(result, AgentSession.metaKey, session.uuidString))
    }

    // MARK: - Result mapping

    private func mapToolResult(id: JSONRPCID, result: ToolResult, note: CallTiming.Note? = nil) -> JSONRPCResponse {
        // The timing note is its own block after the reply's: the reply
        // stays byte for byte as it was.
        let timing: [CallToolContent] = note.map { [.text($0.json)] } ?? []
        switch result {
        case .data(let bytes):
            // Wrap raw JSON in a single text content block. Agents that
            // want structured content can parse the JSON.
            let text = String(data: bytes, encoding: .utf8) ?? ""
            let payload = CallToolResult(content: [.text(text)] + timing, isError: false)
            return successResponse(id: id, body: payload)

        case .proposed(let proposal):
            // Tell the agent what was queued. They can poll
            // get_proposal_state by id.
            let summary = """
            {
              "proposalId": "\(proposal.id.uuidString)",
              "kind": "\(proposal.kind)",
              "summary": \(escapeJSON(proposal.summary))
            }
            """
            let payload = CallToolResult(content: [.text(summary)] + timing, isError: false)
            return successResponse(id: id, body: payload)

        case .failed(let reason):
            let payload = CallToolResult(
                content: [.text(reason.description)] + timing,
                isError: true
            )
            return successResponse(id: id, body: payload)

        case .image(let data, let mimeType, let caption):
            // Inline image block (base64) so the agent can display it, plus an
            // optional metadata text block.
            var blocks: [CallToolContent] = [.image(base64: data.base64EncodedString(), mimeType: mimeType)]
            if let caption, !caption.isEmpty { blocks.append(.text(caption)) }
            let payload = CallToolResult(content: blocks + timing, isError: false)
            return successResponse(id: id, body: payload)
        }
    }

    // MARK: - Per-connection capability bag

    /// The bridge needs concrete proposal/budget instances per connection.
    /// Subclassing the actor for tests would be awkward; instead, the
    /// caller injects them through `init(router:identity:services:approval:)`,
    /// so the bridge can never be served in an unconfigured state.
    public struct PerConnectionServices: Sendable {
        public let proposals: any ProposalStore
        public let budget: ProposalBudget
        public let eventLog: EventLog?
        /// Where this session's log is kept (plan 23); nil keeps none.
        public let recorder: (any AgentSessionRecorder)?
        /// Whether the person has allowed the session (plan 25); nil lets
        /// every call through.
        public let gate: (any AgentSessionGate)?

        public init(proposals: any ProposalStore,
                    budget: ProposalBudget,
                    eventLog: EventLog? = nil,
                    recorder: (any AgentSessionRecorder)? = nil,
                    gate: (any AgentSessionGate)? = nil) {
            self.proposals = proposals
            self.budget = budget
            self.eventLog = eventLog
            self.recorder = recorder
            self.gate = gate
        }
    }

    // MARK: - Helpers

    private func successResponse<T: Encodable>(id: JSONRPCID, body: T) -> JSONRPCResponse {
        do {
            let bytes = try JSONEncoder().encode(body)
            return .success(id: id, result: bytes)
        } catch {
            return .failure(
                id: id,
                error: JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.internalError,
                    message: "encode failed: \(error)"
                )
            )
        }
    }

    private func notInitialized(id: JSONRPCID) -> JSONRPCResponse {
        .failure(id: id, error: JSONRPCErrorPayload(
            code: JSONRPCErrorCode.serverNotInitialized,
            message: "Server has not been initialized."
        ))
    }

    private func invalidParams(_ msg: String) -> JSONRPCErrorPayload {
        JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: msg)
    }

    /// Marker used as the `result` body for methods that succeed but
    /// have nothing to report (`logging/setLevel`, `ping`).
    private struct EmptyObject: Encodable, Sendable {}

    private func escapeJSON(_ s: String) -> String {
        // Thin convenience for the inline summary string above.
        guard let bytes = try? JSONEncoder().encode(s),
              let str = String(data: bytes, encoding: .utf8) else {
            return "\"\""
        }
        return str
    }
}
