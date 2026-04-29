// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit
import MCPCore

/// Owns the lifecycle of the in-process MCP server.
///
/// Responsibilities:
///   * Start and stop a `SocketServer` (AF_UNIX, App Support container).
///   * Publish the listener path through `SocketSidecar` so the
///     `canfar-mcp` helper can find us at any time.
///   * Spawn one `MCPBridgeService` per accepted connection, each with
///     its own per-connection budget but a *shared* proposal store —
///     the strip UI shows all pending agents' proposals.
///   * Hold a `CapturingAuditSink` so the Settings UI can display
///     recent audit entries.
///
/// State surface (`@Observable`):
///   * `isEnabled`   — user toggle, persisted in UserDefaults.
///   * `isRunning`   — whether the listener is currently up.
///   * `connectionCount` — for the Settings status line.
///
/// Tools land in P4 by appending to `tools` before the first start.
/// Once started, the router is fixed for the lifetime of the listener.
@Observable
@MainActor
final class AgentsService {
    // MARK: - Public flags

    /// User-controlled toggle — defaults to *off* so an MCP client can
    /// only reach the app when the user explicitly opts in.
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.userDefaultsKey)
            applyToggle()
        }
    }

    private(set) var isRunning: Bool = false
    private(set) var connectionCount: Int = 0
    private(set) var lastError: String?
    /// Snapshot of pending proposals for SwiftUI binding. Refreshed
    /// after each enqueue/apply/reject so the strip stays current.
    private(set) var pendingProposals: [PendingProposal] = []

    /// Path published to the sidecar; nil when not running. Surfaced for
    /// diagnostics in Settings.
    private(set) var socketPath: String?

    // MARK: - Wiring

    private let identity: MCPBridgeService.ServerIdentity
    private let auditSink: CapturingAuditSink
    private let proposals: any ProposalStore
    private let logger = Logger(subsystem: "com.codebg.Verbinal.agent", category: "service")

    /// Tools registered with the router. Mutate before the first
    /// `start()` — once the listener is up, the router is captured.
    private(set) var tools: [any AITool] = []

    /// Appliers map proposal `kind` → handler invoked when the user
    /// clicks Apply in the strip. Register before tools start producing
    /// proposals; safe to register at any time.
    let applierRegistry = ProposalApplierRegistry()

    private var server: SocketServer?
    private var serverLoopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var router: AIToolRouter?

    // MARK: - Init

    private static let userDefaultsKey = "com.codebg.Verbinal.agents.allowExternalAgents"

    init(
        identity: MCPBridgeService.ServerIdentity = MCPBridgeService.ServerIdentity(
            name: "Verbinal",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            instructions: "Use describe_app for an overview of available tools and the proposal model."
        ),
        proposals: any ProposalStore = InMemoryProposalStore()
    ) {
        self.identity = identity
        self.auditSink = CapturingAuditSink()
        self.proposals = proposals
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
    }

    // MARK: - Tool registration

    /// Register tools. Idempotent for identical tool sets but discards
    /// duplicates by name (the router preconditions on duplicate names,
    /// so we filter here for nicer diagnostics).
    func register(tools newTools: [any AITool]) {
        var byName: [String: any AITool] = Dictionary(
            uniqueKeysWithValues: tools.map { ($0.name, $0) }
        )
        for tool in newTools where byName[tool.name] == nil {
            byName[tool.name] = tool
        }
        self.tools = byName.values.sorted(by: { $0.name < $1.name })
    }

    /// Register one or more proposal appliers. Safe at any time.
    func register(appliers: [any ProposalApplier]) {
        Task { await applierRegistry.register(appliers) }
    }

    // MARK: - Proposal lifecycle (driven by the strip UI)

    /// Apply a pending proposal. Looks up the applier, invokes it, then
    /// marks the proposal applied on success. Surfaces typed errors.
    func applyProposal(_ id: UUID) async throws {
        let pending = await proposals.list(origin: nil)
        guard let proposal = pending.first(where: { $0.id == id }) else {
            throw ProposalApplyError.backendError("proposal not pending: \(id)")
        }
        guard let applier = await applierRegistry.applier(for: proposal.kind) else {
            throw ProposalApplyError.noApplierForKind(proposal.kind)
        }
        do {
            try await applier.apply(proposal)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("\(error)")
        }
        _ = await proposals.markApplied(id)
        await refreshPending()
    }

    /// Reject a pending proposal — sets the tombstone and removes it
    /// from the queue. Idempotent; safe to call after apply.
    func rejectProposal(_ id: UUID) async {
        _ = await proposals.markRejected(id)
        await refreshPending()
    }

    /// Refresh the @Observable `pendingProposals` snapshot from the
    /// store. Called after lifecycle transitions; the strip rebinds.
    func refreshPending() async {
        let snapshot = await proposals.list(origin: nil)
        pendingProposals = snapshot
    }

    // MARK: - Audit

    /// Snapshot recent audit entries for the Settings audit viewer.
    func recentAuditEntries(limit: Int = 50) -> [AuditEntry] {
        let all = auditSink.snapshot()
        return Array(all.suffix(limit))
    }

    // MARK: - Lifecycle

    private func applyToggle() {
        if isEnabled {
            startServer()
        } else {
            stopServer()
        }
    }

    /// Apply persisted state at app launch. Call once after init from
    /// the AppState bootstrap.
    func bootstrap() {
        if isEnabled { startServer() }
    }

    private func startServer() {
        guard !isRunning else { return }

        // Build the router *now* (so any pending tool registration is
        // captured). Audit entries fan out to our capturing sink AND
        // the os.log sink for system-wide visibility.
        let multiSink = MultiplexAuditSink(sinks: [auditSink, LoggingAuditSink()])
        let router = AIToolRouter(tools: tools, auditSink: multiSink)
        self.router = router

        // Compute a fresh socket path for this app instance. Including
        // the PID prevents stale-socket collisions when a previous
        // crashed run left files behind.
        let path = SocketSidecar.suggestedSocketPath()
        let server = SocketServer(socketPath: path)
        do {
            try server.start()
        } catch {
            logger.error("listener start failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = "Listener start failed: \(error.localizedDescription)"
            return
        }
        self.server = server
        self.socketPath = path
        do {
            _ = try SocketSidecar.write(socketPath: path)
        } catch {
            logger.error("sidecar write failed: \(error.localizedDescription, privacy: .public)")
            // Server is up but helper won't find us — surface, don't fail.
            self.lastError = "Sidecar write failed: \(error.localizedDescription)"
        }
        self.isRunning = true
        self.lastError = nil
        self.connectionCount = 0

        // Per-connection serve loop runs detached; it keeps a strong
        // reference to `self` until the server is stopped.
        serverLoopTask = Task { [weak self] in
            guard let stream = self?.server?.connections else { return }
            for await transport in stream {
                guard let self = self else { break }
                await self.handle(connection: transport)
            }
        }

        logger.notice("agents service started at \(path, privacy: .public)")
    }

    private func stopServer() {
        guard isRunning else { return }
        serverLoopTask?.cancel()
        serverLoopTask = nil
        server?.stop()
        server = nil
        SocketSidecar.clear()
        socketPath = nil
        isRunning = false
        connectionCount = 0
        logger.notice("agents service stopped")
    }

    // MARK: - Per-connection handler

    private func handle(connection transport: SocketTransport) async {
        guard let router = router else { return }
        connectionCount += 1
        defer { connectionCount = max(0, connectionCount - 1) }

        // Each connection gets its own bridge + budget. Proposal store is
        // shared so the strip surfaces every agent's pending writes.
        let bridge = MCPBridgeService(
            router: router,
            identity: identity,
            approval: .allowAll  // P3 minimum: gate is the toggle. P8 adds per-client approval.
        )
        await bridge.configure(services: .init(
            proposals: proposals,
            budget: ProposalBudget()
        ))

        // Background poller: refresh the strip's @Observable snapshot
        // periodically while the connection is active. This is coarse
        // (1s) but trivial and keeps the strip current without adding
        // a notification stream to the proposal store.
        let pollerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.refreshPending()
            }
        }
        defer { pollerTask.cancel() }

        await bridge.serve(on: transport)
        await transport.close()
        await refreshPending()
    }
}

/// Fan-out audit sink that delivers each entry to multiple downstream
/// sinks. Lets the service expose entries to the Settings UI *and* to
/// `os.log` simultaneously.
private struct MultiplexAuditSink: AuditSink {
    let sinks: [any AuditSink]

    func record(_ entry: AuditEntry) {
        for sink in sinks { sink.record(entry) }
    }
}
