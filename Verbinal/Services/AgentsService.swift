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
            changes.done("change_setting", "Allow external AI agents to \(isEnabled ? "on" : "off")")
            applyToggle()
        }
    }

    /// When `true`, write proposals from connected agents auto-apply
    /// without requiring a strip click — the agent gets a synchronous
    /// success result instead of a "queued" placeholder. Defaults to
    /// `true` once `isEnabled` is on, on the philosophy that opting in
    /// to MCP at all is the trust signal; the user can dial it back
    /// here if they want strip-confirmed writes again. Persisted.
    var autoApplyWrites: Bool {
        get { permissions != .askForEverything }
        set { permissions = .migrating(autoApplyOn: newValue) }
    }

    /// What an assistant may do without asking, kind by kind (plan 30 A):
    /// what the person allows applies at once, the rest waits in Pending.
    /// Persisted; the old Auto-apply switch reads and sets it above.
    var permissions: ChangePermissions {
        didSet {
            guard oldValue != permissions else { return }
            if let data = try? JSONEncoder().encode(permissions) {
                UserDefaults.standard.set(data, forKey: Self.permissionsKey)
            }
            // It decides whether an assistant's changes wait for the person
            // (plan 23 C): each kind that changed, by its name.
            for kind in ChangeKind.allCases where oldValue.allows(kind) != permissions.allows(kind) {
                changes.done("change_setting", "\(kind.title): \(permissions.allows(kind) ? "allowed" : "ask me")")
            }
        }
    }

    /// Which kind a proposal is by what it acts on — what an assistant made,
    /// an upload over a file (plan 30 A6). Set where that can be looked up
    /// (macOS); without it, its tool's kind.
    var kindResolver: (@MainActor (PendingProposal) async -> ChangeKind)?
    /// Told when an assistant's change has applied, with what it answered.
    var onApplied: (@MainActor (PendingProposal, Data?) -> Void)?
    /// Each proposal's kind as resolved when it was decided.
    private var resolvedKinds: [UUID: ChangeKind] = [:]
    /// Proposals whose apply failed: applied again, each is a retry, and a
    /// launch looks first for what the failed one may have made (plan 30 W4).
    private var failedBefore: Set<UUID> = []

    /// A proposal's kind: as resolved when decided, else its tool's.
    func kind(of proposal: PendingProposal) -> ChangeKind {
        resolvedKinds[proposal.id] ?? ChangeCatalog.kind(of: proposal)
    }

    /// A call still working past its answer, on the activity bar until it
    /// ends: the assistant was told it carries on, and the person sees it
    /// (plan 30 L).
    nonisolated static let carryOn: @Sendable (String, String) async -> (@Sendable (Bool) async -> Void) = { tool, _ in
        let task = await MainActor.run {
            TaskRegistry.shared.begin(.answer, String(localized: "Answering \(tool) for an assistant"))
        }
        return { succeeded in
            await MainActor.run {
                if succeeded { task.succeed() } else { task.fail(String(localized: "It ended without an answer")) }
            }
        }
    }

    /// Whether an assistant's change applies at once: its kind, by what it
    /// acts on, and the person's setting for that kind.
    private func decide(_ proposal: PendingProposal) async -> AutoApplyDecision {
        ChangeCatalog.decision(kind: await resolveKind(proposal), permissions: permissions)
    }

    private func resolveKind(_ proposal: PendingProposal) async -> ChangeKind {
        let kind = await kindResolver?(proposal) ?? ChangeCatalog.kind(of: proposal)
        resolvedKinds[proposal.id] = kind
        return kind
    }

    /// The closing sentence of a proposing tool's description: its kind, and
    /// what the person's setting does with it now.
    func toolRule(_ tool: String) -> String? {
        ChangeCatalog.kind(ofTool: tool).map { AutoApplyPolicy.toolSentence(forChange: $0, permissions: permissions) }
    }

    /// When `true`, after an auto-applied write the app navigates the
    /// user's window to the section where the change is visible (saved
    /// queries → Search, observation notes / downloads → Research,
    /// VOSpace edits → Storage, sessions → Portal). Default ON so the
    /// user always sees motion when the agent does work; turn off to
    /// stay focused. Independent of the agent's explicit
    /// `navigate_to` tool, which always works.
    var followAgentActivity: Bool {
        didSet {
            guard oldValue != followAgentActivity else { return }
            UserDefaults.standard.set(followAgentActivity, forKey: Self.followActivityKey)
            changes.done("change_setting", "Follow the assistant's activity to \(followAgentActivity ? "on" : "off")")
        }
    }

    /// Closure the host wires so the auto-apply path can drive
    /// navigation. Optional because pre-bootstrap (and in tests) there
    /// may be no UI to drive. Set by AppState during initialize().
    var navigator: (@Sendable (AppMode) async -> Void)?

    /// AI Guide hook the host wires so `tools/list`/`tools/call` reflect the
    /// user's description overrides + guide tools. Optional (nil in tests / on
    /// iOS). Set by AppState during initialize(), before the listener starts.
    var aiGuideResolver: AIGuideResolver?

    private(set) var isRunning: Bool = false
    private(set) var connectionCount: Int = 0
    private(set) var lastError: String?
    /// Snapshot of pending proposals for SwiftUI binding. Refreshed
    /// after each enqueue/apply/reject so the strip stays current.
    private(set) var pendingProposals: [PendingProposal] = []
    /// Why the last apply of a pending proposal failed, by id.
    private(set) var applyFailures: [UUID: String] = [:]
    /// Proposals being applied now — by the strip, auto-apply, or a
    /// background job — so the strip shows them as applying, not "Apply".
    private(set) var applyingIDs: Set<UUID> = []
    /// Applies that outlived their call, for `get_job_status`.
    let applyJobs = ApplyJobRegistry()

    /// Path published to the sidecar; nil when not running. Surfaced for
    /// diagnostics in Settings.
    private(set) var socketPath: String?

    // MARK: - Wiring

    private let identity: MCPBridgeService.ServerIdentity
    private let auditSink: CapturingAuditSink
    private let proposals: any ProposalStore
    /// Single event log shared across all connections — agents call
    /// `list_events` to observe proposal lifecycle transitions without
    /// per-proposal polling. In-memory; not for the user-facing UI.
    let eventLog: EventLog
    /// User-facing persistent breadcrumb of agent activity. Distinct
    /// from `eventLog`: this survives app restarts and is what the
    /// toolbar wand popover, per-row badges, and "what did the agent
    /// do recently" surfaces all read from.
    let activityStore = AgentActivityStore()
    /// Transient live feed for the top-of-window agent-activity snackbar.
    /// Fed by a push audit sink on every dispatch (reads included);
    /// distinct from `activityStore` (persistent, writes only).
    let liveActivity = AgentLiveActivity()
    /// A sound when an agent starts using the app, and one when it stops.
    let sounds = AgentSounds()
    private let logger = Logger(subsystem: "com.codebg.Verbinal.agent", category: "service")

    /// Tools registered with the router. Mutate before the first
    /// `start()` — once the listener is up, the router is captured.
    private(set) var tools: [any AITool] = []

    /// Appliers map proposal `kind` → handler invoked when the user
    /// clicks Apply in the strip. Register before tools start producing
    /// proposals; safe to register at any time.
    let applierRegistry = ProposalApplierRegistry()
    /// Where an applied change is recorded (plan 23 C).
    let changes: ChangeLog = .shared
    /// Where each connected assistant's session log is kept (plan 23 L2);
    /// the app sets it before the server starts.
    var sessionRecorder: (any AgentSessionRecorder)?
    /// Whether the person has allowed a connection's session (plan 25); nil
    /// lets every call through.
    var sessionGate: (any AgentSessionGate)?

    private var server: SocketServer?
    private var serverLoopTask: Task<Void, Never>?
    private var router: AIToolRouter?
    /// In-flight agent connections, keyed by a per-connection token. Each
    /// is served on its own task (see `serveConcurrently`) so one
    /// long-lived client can't starve the others; tracked here only so a
    /// shutdown can close them promptly.
    private var activeConnections: [UUID: SocketTransport] = [:]

    // MARK: - Init

    private static let userDefaultsKey = "com.codebg.Verbinal.agents.allowExternalAgents"
    private static let autoApplyKey = "com.codebg.Verbinal.agents.autoApplyWrites"
    private static let permissionsKey = "com.codebg.Verbinal.agents.changePermissions"
    private static let followActivityKey = "com.codebg.Verbinal.agents.followAgentActivity"

    /// Who answers, and what every assistant is told first (plan 25 W).
    static let serverIdentity = MCPBridgeService.ServerIdentity(
        name: "Verbinal",
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
        instructions: AgentSession.instructions + " Then call `describe_app` for the tool surface and the autonomy model. Call `get_current_view` to see the user's current screen and `autoApplyEnabled` — it tells you whether your writes apply immediately or queue for the user to review in the strip. Give every write a `why`. When something is slow or failed, read the reply's `timing` block, then `explain_log_entry` with its `logToken`, then `get_session_log` (its `now` says what is happening)."
    )

    init(
        identity: MCPBridgeService.ServerIdentity = AgentsService.serverIdentity,
        proposals injected: (any ProposalStore)? = nil
    ) {
        self.identity = identity
        self.auditSink = CapturingAuditSink()
        // Build the event log first so the proposal store can fan-out
        // arrivals/applications/rejections/withdrawals to it.
        let log = EventLog()
        self.eventLog = log
        let journal = DiskPersistence<ProposalJournal>(
            subdirectory: "Verbinal",
            fileName: "pending_proposals.json",
            logger: Logger(subsystem: "com.codebg.Verbinal.agent", category: "proposals")
        )
        // A test hands in its own store, so it never reads or writes the person's.
        self.proposals = injected ?? InMemoryProposalStore(eventLog: log, journal: journal)
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
        // First-launch default for the autonomy toggle: ON. Subsequent
        // launches honour whatever the user last set. UserDefaults
        // returns false for missing bools, so we register a default.
        UserDefaults.standard.register(defaults: [
            Self.autoApplyKey: true,
            Self.followActivityKey: true
        ])
        // The person's choices; before there were any, the old switch's.
        if let data = UserDefaults.standard.data(forKey: Self.permissionsKey),
           let stored = try? JSONDecoder().decode(ChangePermissions.self, from: data) {
            self.permissions = stored
        } else {
            self.permissions = .migrating(autoApplyOn: UserDefaults.standard.bool(forKey: Self.autoApplyKey))
        }
        self.followAgentActivity = UserDefaults.standard.bool(forKey: Self.followActivityKey)
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
    /// marks the proposal applied on success, by `actor` — the person from
    /// Pending, auto-apply, or an agent's background start — which the
    /// applied event and the activity feed keep. Surfaces typed errors.
    func applyProposal(_ id: UUID, by actor: ApplyActor) async throws {
        _ = try await applyProposalReturningResult(id, by: actor)
    }

    /// Same as `applyProposal`, but returns extra JSON for the auto-apply
    /// ack when the applier is a `ResultReportingApplier`.
    func applyProposalReturningResult(_ id: UUID, by actor: ApplyActor) async throws -> Data? {
        let pending = await proposals.list(origin: nil)
        guard let proposal = pending.first(where: { $0.id == id }) else {
            throw ProposalApplyError.backendError("proposal not pending: \(id)")
        }
        guard let applier = await applierRegistry.applier(for: proposal.kind) else {
            throw ProposalApplyError.noApplierForKind(proposal.kind)
        }
        // One apply per change: a second Apply (or an agent's background
        // start) while the first runs would do the work twice.
        guard await proposals.beginApply(id) else {
            throw ProposalApplyError.backendError("\(proposal.kind) is already being applied")
        }
        applyingIDs.insert(id)
        defer { applyingIDs.remove(id) }
        let extra: Data?
        let retry = failedBefore.contains(id)
        do {
            // The change is the assistant's, whoever approved it (plan 17 A1),
            // its cause is the proposal's — its why, its call and session, and
            // who applied it (plan 23 K) — and it is recorded here, once, for
            // every kind of change an assistant makes (plan 23 C).
            extra = try await Initiator.$current.withValue(.assistant) {
                try await changes.applying(proposal, by: actor) {
                    try await ApplyAttempt.$isRetry.withValue(retry) {
                        if let reporting = applier as? any ResultReportingApplier {
                            return try await reporting.applyReturningResult(proposal)
                        }
                        try await applier.apply(proposal)
                        return nil
                    }
                }
            }
        } catch {
            // The reason stays on the proposal, for the strip and
            // get_proposal_state, however the apply was started (QA N7).
            let failure = error as? ProposalApplyError ?? .backendError("\(error)")
            failedBefore.insert(id)
            _ = await proposals.markApplyFailed(id, reason: failure.message)
            await refreshPending()
            throw failure
        }
        _ = await proposals.markApplied(id, by: actor)
        activityStore.markApplied(forProposal: id, by: actor)
        // What it made is an assistant's; what it removed is gone (plan 30 A6).
        onApplied?(proposal, extra)
        resolvedKinds[id] = nil
        failedBefore.remove(id)
        if actor != .person {
            if followAgentActivity,
               let target = Self.navigationTarget(forKind: proposal.kind),
               let nav = navigator {
                await nav(target)
            }
        }
        await refreshPending()
        return extra
    }

    /// The proposals waiting for the person, each with what holds it (plan
    /// 23 L3, plan 30 W3): their setting for its kind, or a failed apply to
    /// try again. One being applied is not waiting: it is a running task.
    func waitingProposals() async -> [(proposal: PendingProposal, waits: String)] {
        var waiting: [(PendingProposal, String)] = []
        for proposal in await proposals.list(origin: nil) {
            switch await proposals.state(proposal.id) {
            case .applying:
                continue
            case .failed:
                waiting.append((proposal, "failed when it was applied; it waits for the person to try again or discard it"))
            default:
                waiting.append((proposal, Self.waitingRule(proposal, kind: kind(of: proposal), permissions: permissions)))
            }
        }
        return waiting
    }

    /// Why a proposal still in Pending waits: the person asks to approve its
    /// kind — or allowed it only after it was proposed.
    nonisolated static func waitingRule(_ proposal: PendingProposal, kind: ChangeKind? = nil,
                                        permissions: ChangePermissions) -> String {
        let kind = kind ?? ChangeCatalog.kind(of: proposal)
        return permissions.allows(kind)
            ? "waits in Pending: it was proposed before the person allowed \"\(kind.title)\"; they apply it, or start_background_apply can"
            : AutoApplyPolicy.rule(forChange: kind, appliedAtOnce: false)
    }

    // MARK: - Background applies

    /// What `start_background_apply` answered.
    struct BackgroundStart: Encodable, Sendable {
        let started: Bool
        let jobId: String?
        let kind: String?
        let summary: String?
        let status: String
        let message: String
    }

    /// Why a pending proposal may not be started in the background, or nil.
    /// The person's approval is not the agent's to give: only a kind they
    /// allow may start (plan 30 A).
    nonisolated static func backgroundRefusal(_ proposal: PendingProposal, kind: ChangeKind? = nil,
                                              permissions: ChangePermissions) -> String? {
        let decision = ChangeCatalog.decision(kind: kind ?? ChangeCatalog.kind(of: proposal), permissions: permissions)
        guard !decision.appliesAtOnce else { return nil }
        return "'\(proposal.kind)' \(decision.rule): only the person can apply it"
    }

    /// Starts applying a pending proposal without holding the call open.
    func startBackgroundApply(_ raw: String) async -> BackgroundStart {
        func refused(_ message: String) -> BackgroundStart {
            BackgroundStart(started: false, jobId: nil, kind: nil, summary: nil, status: "notStarted", message: message)
        }
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            return refused("'\(raw)' is not a proposal id — list_pending_proposals reports them")
        }
        guard let proposal = await proposals.list(origin: nil).first(where: { $0.id == id }) else {
            return refused("no pending proposal '\(raw)' — list_pending_proposals shows the ones there are")
        }
        if let why = Self.backgroundRefusal(proposal, kind: await resolveKind(proposal), permissions: permissions) {
            return refused(why)
        }
        if await proposals.state(id) == .applying {
            return refused("'\(proposal.kind)' is already being applied — follow it with get_job_status")
        }
        let jobs = applyJobs
        await jobs.start(proposal)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.applyProposalReturningResult(id, by: .background)
                await jobs.succeed(id, result: result)
            } catch {
                await jobs.fail(id, message: error.localizedDescription)
            }
        }
        return BackgroundStart(started: true, jobId: id.uuidString, kind: proposal.kind, summary: proposal.summary,
                               status: "running", message: "started; follow it with get_job_status")
    }

    /// A job's state, or — for an id that never ran as a job — what the
    /// proposal queue knows of it.
    func jobStatus(_ raw: String) async -> (job: ApplyJobRegistry.Job?, state: ProposalState)? {
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (await applyJobs.job(id), await proposals.state(id))
    }

    /// Map a proposal `kind` to the AppMode whose view will reflect the
    /// change. Centralizing the table keeps it reviewable; new kinds
    /// either add an entry here or fall through to `nil` (no
    /// follow-on navigation).
    static func navigationTarget(forKind kind: String) -> AppMode? {
        switch kind {
        case "save_query", "update_saved_query", "delete_saved_query":
            return .search
        case "update_observation_note", "bulk_update_observation_notes",
             "download_observation", "download_observations_bulk",
             "delete_downloaded_observation", "clear_research_archive":
            return .research
        case "upload_to_vospace", "upload_text_to_vospace", "upload_file_to_vospace",
             "download_from_vospace",
             "vospace_mkdir", "delete_vospace_node":
            return .storage
        case "launch_session", "delete_session", "delete_sessions_bulk",
             "launch_headless_job", "discover_image_packages":
            return .portal
        // INTENTIONALLY OMITTED — `clear_user_site` falls through to nil.
        // It wipes ~/.local/lib/python3.*/site-packages, which has no
        // user-visible UI surface, so navigating to Storage afterward
        // would mislead rather than help. This is a deliberate gap, not
        // the same defect as the once-missing delete_sessions_bulk /
        // upload_text_to_vospace cases — do not add a navigation here.
        default:
            return nil
        }
    }

    /// Reject a pending proposal — sets the tombstone and removes it
    /// from the queue. Idempotent; safe to call after apply.
    func rejectProposal(_ id: UUID) async {
        // Snapshot the proposal *before* we mark it rejected so the
        // activity feed entry carries the kind/summary/origin that the
        // tombstoned proposal would otherwise drop.
        let snapshot = await proposals.list(origin: nil).first(where: { $0.id == id })
        _ = await proposals.markRejected(id)
        if let snapshot {
            activityStore.append(.rejected(proposal: snapshot))
        }
        await refreshPending()
    }

    /// Refresh the @Observable `pendingProposals` snapshot from the
    /// store. Called after lifecycle transitions; the strip rebinds.
    func refreshPending() async {
        let snapshot = await proposals.list(origin: nil)
        var failures: [UUID: String] = [:]
        for proposal in snapshot {
            if let reason = await proposals.failureReason(proposal.id) { failures[proposal.id] = reason }
        }
        applyFailures = failures
        // What left Pending by waiting out its time goes into History.
        let still = Set(snapshot.map(\.id))
        for gone in pendingProposals where !still.contains(gone.id) {
            if await proposals.state(gone.id) == .expired { activityStore.append(.expired(proposal: gone)) }
        }
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
        Task { await refreshPending() }
        if isEnabled { startServer() }
    }

    /// The tool list as agents see it (`tools/list`): empty until the
    /// server has started. The tool-map tools read this.
    func publishedTools() async -> [ToolDefinitionWire] {
        guard let router else { return [] }
        return await PublishedManifest.tools(router: router, aiGuide: aiGuideResolver, rule: { [weak self] tool, _ in
            await self?.toolRule(tool)
        })
    }

    private func startServer() {
        guard !isRunning else { return }

        // Build the router *now* (so any pending tool registration is
        // captured). Audit entries fan out to our capturing sink AND
        // the os.log sink for system-wide visibility.
        let multiSink = MultiplexAuditSink(sinks: [auditSink, LoggingAuditSink()])
        // Live snackbar feed: the router pulses at dispatch START for
        // every external agent call (reads included) — Windows
        // `onAgentDispatchStart` parity — so the banner is up while a
        // slow call runs instead of only flashing after it completes.
        // The router fires this only for `.external` origins; hop to
        // the main actor to update the @Observable feed.
        let liveActivity = self.liveActivity
        let sounds = self.sounds
        let onDispatchStart: @Sendable (String, String) -> Void = { tool, label in
            Task { @MainActor in
                liveActivity.record(originLabel: label, toolName: tool)
                sounds.agentCalled()
            }
        }
        let hook = AutoApplyHook(
            // What the person allows, kind by kind (plan 30 A): an allowed
            // change applies at once, the rest waits in Pending for them.
            decide: { [weak self] _, proposal in
                guard let self else {
                    return AutoApplyDecision(appliesAtOnce: false, rule: "waits in Pending: Verbinal is closing")
                }
                return await self.decide(proposal)
            },
            apply: { [weak self] id in
                guard let self else {
                    throw ProposalApplyError.backendError("AgentsService deallocated")
                }
                return try await self.applyProposalReturningResult(id, by: .autoApply)
            }
        )
        let router = AIToolRouter(tools: tools, auditSink: multiSink,
                                  autoApplyHook: hook, onDispatchStart: onDispatchStart,
                                  applyJobs: applyJobs,
                                  onCarryOn: Self.carryOn)
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

        // Accept loop: pull each connection off the stream and serve it on
        // its OWN task. Serving MUST NOT block the accept loop —
        // `serve(on:)` runs for the entire lifetime of a connection, and
        // MCP clients (Claude Desktop especially) hold an idle connection
        // open for the whole session. Awaiting `handle` serially here meant
        // the *first* connection monopolised the only consumer slot and
        // every later connection (Claude Code, a second client, or a stale
        // prior connection) was accepted but never serviced — the root
        // cause of "Verbinal never shows up as an MCP server".
        serverLoopTask = Task { [weak self] in
            guard let stream = self?.server?.connections else { return }
            for await transport in stream {
                guard let self = self else { break }
                self.serveConcurrently(transport)
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
        // Close any in-flight agent connections so their serve loops end
        // now instead of lingering until each client happens to hang up.
        let live = Array(activeConnections.values)
        activeConnections.removeAll()
        if !live.isEmpty {
            Task { for transport in live { await transport.close() } }
        }
        SocketSidecar.clear()
        socketPath = nil
        isRunning = false
        connectionCount = 0
        logger.notice("agents service stopped")
    }

    // MARK: - Per-connection handler

    /// Serve one accepted connection on a dedicated task so concurrent
    /// clients are independent. The connection is tracked in
    /// `activeConnections` for the duration so a shutdown can close it;
    /// the task self-removes on completion. See the accept loop in
    /// `startServer` for why serial serving was the MCP-server bug.
    private func serveConcurrently(_ transport: SocketTransport) {
        let token = UUID()
        activeConnections[token] = transport
        Task { [weak self] in
            await self?.handle(connection: transport)
            self?.activeConnections[token] = nil
        }
    }

    private func handle(connection transport: SocketTransport) async {
        guard let router = router else { return }
        connectionCount += 1
        defer { connectionCount = max(0, connectionCount - 1) }

        // Each connection gets its own bridge + budget. Proposal store is
        // shared so the strip surfaces every agent's pending writes.
        let bridge = MCPBridgeService(
            router: router,
            identity: identity,
            services: .init(
                proposals: proposals,
                budget: ProposalBudget(),
                eventLog: eventLog,
                recorder: sessionRecorder,
                gate: sessionGate
            ),
            approval: .allowAll,  // P3 minimum: gate is the toggle. P8 adds per-client approval.
            aiGuide: aiGuideResolver,
            toolRule: { [weak self] tool, _ in await self?.toolRule(tool) }
        )

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
