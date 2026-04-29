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

    public enum BridgeError: Error, Equatable {
        case notInitialized
        case transportClosed
    }

    /// Pluggable approval gate. Returns `true` if the connecting client
    /// is permitted to proceed beyond `initialize`. Default
    /// implementations: `.allowAll` (dev), `.deny` (Settings off),
    /// `.userApproval` (sheet — wired in Phase 3).
    public struct ApprovalGate: Sendable {
        public let permit: @Sendable (_ clientID: String, _ clientInfo: ClientInfo?) async -> Bool

        public init(permit: @escaping @Sendable (_ clientID: String, _ clientInfo: ClientInfo?) async -> Bool) {
            self.permit = permit
        }

        public static let allowAll = ApprovalGate { _, _ in true }
        public static let deny = ApprovalGate { _, _ in false }
    }

    private let router: AIToolRouter
    private let identity: ServerIdentity
    private let approval: ApprovalGate
    private let logger = Logger(subsystem: "com.codebg.Verbinal.agent", category: "bridge")

    /// Per-connection state. Initialized lazily on the first `initialize`
    /// request — anything before that returns `serverNotInitialized`.
    private var clientID: String?
    private var initialized: Bool = false

    public init(
        router: AIToolRouter,
        identity: ServerIdentity,
        approval: ApprovalGate = .allowAll
    ) {
        self.router = router
        self.identity = identity
        self.approval = approval
    }

    /// Drive the connection. Returns when the transport closes.
    public func serve(on transport: any MCPTransport) async {
        logger.info("connection opened")
        defer { logger.info("connection closed") }
        do {
            for try await frame in transport.incoming {
                if frame.isEmpty { continue } // skip ndjson keep-alives
                await handleIncoming(frame: frame, transport: transport)
            }
        } catch {
            logger.notice("transport ended: \(String(describing: error), privacy: .public)")
        }
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

        let response: JSONRPCResponse
        switch request.method {
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

        do {
            let bytes = try JSONEncoder().encode(response)
            try await transport.send(bytes)
            let outcome = response.error != nil ? "error" : "ok"
            logger.debug("send \(methodForLog, privacy: .public) id=\(idForLog, privacy: .public) (\(bytes.count) bytes, \(outcome, privacy: .public))")
        } catch {
            logger.error("send failed: \(error.localizedDescription, privacy: .public)")
        }
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

        self.clientID = cid
        self.initialized = true
        logger.info("initialized client=\(cid, privacy: .public)")

        let result = InitializeResult(
            protocolVersion: params.protocolVersion,
            capabilities: ServerCapabilities(
                tools: .init(listChanged: false),
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
        let manifest = await router.externalManifestList()
        let tools = manifest.map { $0.wire }
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
            eventLog: services.eventLog
        )

        logger.info("tools/call \(params.name, privacy: .public) (\(argBytes.count) bytes args)")
        let result = await router.dispatch(
            name: params.name,
            rawArguments: argBytes,
            context: context
        )
        switch result {
        case .data(let bytes):
            logger.info("tools/call \(params.name, privacy: .public) -> data (\(bytes.count) bytes)")
        case .proposed(let proposal):
            logger.info("tools/call \(params.name, privacy: .public) -> proposed kind=\(proposal.kind, privacy: .public) id=\(proposal.id.uuidString, privacy: .public)")
        case .failed(let reason):
            logger.notice("tools/call \(params.name, privacy: .public) -> failed (\(reason.auditTag, privacy: .public))")
        }
        return mapToolResult(id: request.id, result: result)
    }

    // MARK: - Result mapping

    private func mapToolResult(id: JSONRPCID, result: ToolResult) -> JSONRPCResponse {
        switch result {
        case .data(let bytes):
            // Wrap raw JSON in a single text content block. Agents that
            // want structured content can parse the JSON.
            let text = String(data: bytes, encoding: .utf8) ?? ""
            let payload = CallToolResult(content: [.text(text)], isError: false)
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
            let payload = CallToolResult(content: [.text(summary)], isError: false)
            return successResponse(id: id, body: payload)

        case .failed(let reason):
            let payload = CallToolResult(
                content: [.text(reason.description)],
                isError: true
            )
            return successResponse(id: id, body: payload)
        }
    }

    // MARK: - Per-connection capability bag

    /// The bridge needs concrete proposal/budget instances per connection.
    /// Subclassing the actor for tests would be awkward; instead, the
    /// caller injects them by setting `services` before `serve(on:)`.
    public struct PerConnectionServices: Sendable {
        public let proposals: any ProposalStore
        public let budget: ProposalBudget
        public let eventLog: EventLog?

        public init(proposals: any ProposalStore,
                    budget: ProposalBudget,
                    eventLog: EventLog? = nil) {
            self.proposals = proposals
            self.budget = budget
            self.eventLog = eventLog
        }
    }

    private var _services: PerConnectionServices?
    private var services: PerConnectionServices {
        guard let s = _services else {
            preconditionFailure("MCPBridgeService: services were not configured before serve(on:)")
        }
        return s
    }

    public func configure(services: PerConnectionServices) {
        _services = services
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
