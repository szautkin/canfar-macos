// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What an assistant launches as Verbinal's MCP server (`Verbinal mcp`): it
/// relays between the assistant (stdio) and the running app (socket), and
/// keeps the assistant's session alive while the app is not there.
///
/// An assistant that finds a server failing its handshake gives up on it for
/// the session, and one whose server exits loses its tools until reconnected
/// by hand. So while Verbinal is closed the bridge answers the handshake
/// itself, lists the tools the app listed last time, and answers each call
/// with a tool error saying what to open — something the assistant reads,
/// not a protocol error. When the app appears it replays the assistant's
/// handshake to it and tells the assistant its tool list has changed; when
/// the app quits mid-call, every request it was holding gets an answer.
public actor ResilientBridge {

    public struct Configuration: Sendable {
        public var serverName: String
        public var serverVersion: String
        /// The tool error and handshake instructions while the app is closed.
        public var notRunningMessage: String
        public var reconnectInterval: Duration
        /// How long a replayed handshake may take (the app may ask the user
        /// to approve the assistant).
        public var handshakeTimeout: Duration
        /// How long the assistant's first messages wait for the first
        /// connection attempt. Past it they are answered as if the app were
        /// closed, and a late connection replays the handshake — an attempt
        /// stuck in the file system must not leave the handshake unanswered.
        public var firstConnectGrace: Duration

        public init(serverName: String, serverVersion: String, notRunningMessage: String,
                    reconnectInterval: Duration = .seconds(2), handshakeTimeout: Duration = .seconds(120),
                    firstConnectGrace: Duration = .seconds(3)) {
            self.serverName = serverName
            self.serverVersion = serverVersion
            self.notRunningMessage = notRunningMessage
            self.reconnectInterval = reconnectInterval
            self.handshakeTimeout = handshakeTimeout
            self.firstConnectGrace = firstConnectGrace
        }
    }

    private let client: any MCPTransport
    private let connect: @Sendable () async -> (any MCPTransport)?
    private let manifest: ToolManifestCache
    private let configuration: Configuration
    private let log: @Sendable (String) -> Void

    private var app: (any MCPTransport)?
    /// Bumped per app connection so a late frame from a closed one is ignored.
    private var generation = 0
    /// The assistant's own `initialize`, replayed to each new app connection.
    private var clientInitialize: JSONRPCRequest?
    private var clientSentInitialized = false
    /// Requests relayed to the app and not yet answered, by id → method.
    private var pending: [JSONRPCID: String] = [:]
    private var handshake: (id: JSONRPCID, waiter: CheckedContinuation<JSONRPCResponse?, Never>)?
    private var reconnecting: Task<Void, Never>?
    /// The app refused this assistant; asking again would only ask the user again.
    private var refused = false

    public init(client: any MCPTransport,
                connect: @escaping @Sendable () async -> (any MCPTransport)?,
                manifest: ToolManifestCache,
                configuration: Configuration,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.client = client
        self.connect = connect
        self.manifest = manifest
        self.configuration = configuration
        self.log = log
    }

    /// Relays until the assistant hangs up.
    public func run() async {
        let first = Task { if await !self.attach() { self.startReconnecting() } }
        await Self.wait(for: first, atMost: configuration.firstConnectGrace)
        do {
            for try await frame in client.incoming { await fromClient(frame) }
        } catch {
            log("client stream ended: \(error)")
        }
        reconnecting?.cancel()
        await app?.close()
    }

    // MARK: - Assistant → app

    private func fromClient(_ frame: Data) async {
        let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: frame)
        let isRequest = request.map { $0.id != .null } ?? false
        if let request, request.method == "initialize", isRequest { clientInitialize = request }
        if request?.method == "notifications/initialized" { clientSentInitialized = true }

        if let app {
            // Recorded before sending: the answer can arrive while `send` awaits.
            if let request, isRequest { pending[request.id] = request.method }
            do {
                try await app.send(frame)
                return
            } catch {
                log("app send failed: \(error)")
                if let request, isRequest { pending[request.id] = nil }
                await appClosed(generation: generation)
            }
        }
        // Detached. Notifications need no answer; anything unparseable is
        // left for the app to reject once it is back.
        guard let request, isRequest else { return }
        await answerWhileClosed(request)
    }

    private func answerWhileClosed(_ request: JSONRPCRequest) async {
        let message = configuration.notRunningMessage
        switch request.method {
        case "initialize":
            let version = request.params
                .flatMap { try? JSONDecoder().decode(InitializeParams.self, from: $0) }?
                .protocolVersion ?? "2025-06-18"
            await reply(request.id, InitializeResult(
                protocolVersion: version,
                capabilities: ServerCapabilities(
                    tools: .init(listChanged: true),
                    resources: .init(subscribe: false, listChanged: false),
                    logging: .object([:])),
                serverInfo: ServerInfo(name: configuration.serverName, version: configuration.serverVersion),
                instructions: message))
        case "tools/list":
            await reply(request.id, ListToolsResult(tools: manifest.load()))
        case "tools/call":
            await reply(request.id, CallToolResult(content: [.text(message)], isError: true))
        case "resources/list":
            await reply(request.id, ListResourcesResult(resources: []))
        case "ping", "logging/setLevel":
            await reply(request.id, JSONValue.object([:]))
        default:
            await send(.failure(id: request.id, error: JSONRPCErrorPayload(
                code: JSONRPCErrorCode.serviceUnavailable, message: message)))
        }
    }

    // MARK: - App → assistant

    private func fromApp(_ frame: Data, generation gen: Int) async {
        guard gen == generation else { return }
        let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
        let isResponse = object != nil && object?["method"] == nil
        if isResponse, let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: frame) {
            if let handshake, handshake.id == response.id {
                self.handshake = nil
                handshake.waiter.resume(returning: response)
                return
            }
            if pending.removeValue(forKey: response.id) == "tools/list", let result = response.result,
               let list = try? JSONDecoder().decode(ListToolsResult.self, from: result) {
                manifest.save(list.tools)
            }
        }
        do { try await client.send(frame) } catch { log("client send failed: \(error)") }
    }

    private func appClosed(generation gen: Int) async {
        guard gen == generation, app != nil || handshake != nil else { return }
        log("app connection closed")
        app = nil
        if let handshake {
            self.handshake = nil
            handshake.waiter.resume(returning: nil)
        }
        let unanswered = pending
        pending.removeAll()
        for (id, method) in unanswered {
            await send(.failure(id: id, error: JSONRPCErrorPayload(
                code: JSONRPCErrorCode.serviceUnavailable,
                message: "Verbinal closed before answering \(method). \(configuration.notRunningMessage)")))
        }
        startReconnecting()
    }

    // MARK: - Connecting

    /// Connects to the app and, when the assistant has already shaken hands
    /// with the bridge, replays that handshake. True once relaying.
    private func attach() async -> Bool {
        guard let link = await connect() else { return false }
        generation += 1
        let gen = generation
        Task { [weak self] in
            do {
                for try await frame in link.incoming { await self?.fromApp(frame, generation: gen) }
            } catch {}
            await self?.appClosed(generation: gen)
        }
        if let initialize = clientInitialize {
            guard await replay(initialize, over: link, generation: gen) else {
                generation += 1   // the link is abandoned; ignore what it still sends
                await link.close()
                return false
            }
        }
        app = link
        log("attached to the app")
        if clientInitialize != nil {
            await notifyClient("notifications/tools/list_changed")
        }
        return true
    }

    private func replay(_ initialize: JSONRPCRequest, over link: any MCPTransport, generation gen: Int) async -> Bool {
        let id = JSONRPCID.string("verbinal-bridge-handshake-\(gen)")
        let replayed = JSONRPCRequest(id: id, method: initialize.method, params: initialize.params)
        guard let bytes = try? JSONEncoder().encode(replayed) else { return false }
        let timeout = configuration.handshakeTimeout
        let response: JSONRPCResponse? = await withCheckedContinuation { waiter in
            handshake = (id, waiter)
            Task { [weak self] in
                do { try await link.send(bytes) } catch { await self?.abandonHandshake(id) }
                try? await Task.sleep(for: timeout)
                await self?.abandonHandshake(id)
            }
        }
        guard let response, response.error == nil else {
            if response?.error?.code == JSONRPCErrorCode.sessionNotApproved {
                refused = true
                log("the app did not approve this assistant; not asking again")
            }
            return false
        }
        if clientSentInitialized {
            let note = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            try? await link.send(Data(note.utf8))
        }
        return true
    }

    private func abandonHandshake(_ id: JSONRPCID) {
        guard let handshake, handshake.id == id else { return }
        self.handshake = nil
        handshake.waiter.resume(returning: nil)
    }

    private func startReconnecting() {
        guard reconnecting == nil, !refused else { return }
        let interval = configuration.reconnectInterval
        reconnecting = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                if await self.reconnectOnce() { return }
            }
        }
    }

    /// One attempt; true when the loop should stop.
    private func reconnectOnce() async -> Bool {
        if await attach() || refused {
            reconnecting = nil
            return true
        }
        return false
    }

    /// Returns when `task` finishes or `limit` passes, whichever is first;
    /// `task` itself carries on.
    private static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { await task.value; once.resume() }
            Task { try? await Task.sleep(for: limit); once.resume() }
        }
    }

    // MARK: - Sending

    private func reply<Body: Encodable>(_ id: JSONRPCID, _ body: Body) async {
        do {
            await send(.success(id: id, result: try JSONEncoder().encode(body)))
        } catch {
            await send(.failure(id: id, error: JSONRPCErrorPayload(
                code: JSONRPCErrorCode.internalError, message: "\(error)")))
        }
    }

    private func send(_ response: JSONRPCResponse) async {
        guard let bytes = try? JSONEncoder().encode(response) else { return }
        do { try await client.send(bytes) } catch { log("client send failed: \(error)") }
    }

    private func notifyClient(_ method: String) async {
        let note = #"{"jsonrpc":"2.0","method":"\#(method)"}"#
        do { try await client.send(Data(note.utf8)) } catch { log("client send failed: \(error)") }
    }
}

/// Resumes a continuation from whichever caller gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }?.resume()
    }
}
