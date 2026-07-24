// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Holds the authoritative table of registered tools and dispatches calls.
///
/// Construction is the *single composition point* — every tool the host
/// app wants to expose is constructed at startup and passed in. After
/// that the table is read-only; new tools can't be registered at runtime
/// (which keeps the surface auditable).
///
/// Concurrency model: actor-isolated state, but the dispatch path runs
/// most of the actual work synchronously (table lookup is cheap; the
/// tool's `invoke` is async and the actor awaits it). Audit emit and
/// budget gating happen *after* the tool returns so a failing budget
/// reservation can withdraw the proposal before we reply to the agent.
public actor AIToolRouter {

    public struct ToolMetadata: Sendable, Equatable {
        public let agentSafe: Bool
        public let verbClass: VerbClass
    }

    private let table: [String: any AITool]
    private let metadata: [String: ToolMetadata]
    private let manifest: [AIToolDefinition]
    private let externalManifest: [AIToolDefinition]
    private let auditSink: any AuditSink
    /// Optional hook installed by the host. When set, the router
    /// consults it for write proposals — `true` means the tool call
    /// returns a synchronous applied result, not a queued proposal.
    /// `nil` preserves the strict proposal-strip flow.
    private let autoApplyHook: AutoApplyHook?
    /// Test seam: overrides `dispatchCeiling(for:)` for every verb class
    /// so the hard-deadline path can be exercised in milliseconds.
    private let dispatchCeilingOverride: TimeInterval?
    /// Fired when an EXTERNAL agent call starts dispatching — before the
    /// tool runs, so a UI "agent is working" indicator shows during slow
    /// and failing calls too (Windows `onAgentDispatchStart` parity).
    /// Best-effort and synchronous; hosts hop to their own actor.
    private let onDispatchStart: (@Sendable (_ toolName: String, _ originLabel: String) -> Void)?

    public init(
        tools: [any AITool],
        auditSink: any AuditSink = LoggingAuditSink(),
        autoApplyHook: AutoApplyHook? = nil,
        dispatchCeilingOverride: TimeInterval? = nil,
        onDispatchStart: (@Sendable (_ toolName: String, _ originLabel: String) -> Void)? = nil
    ) {
        var table: [String: any AITool] = [:]
        var metadata: [String: ToolMetadata] = [:]
        var manifest: [AIToolDefinition] = []
        var externalManifest: [AIToolDefinition] = []
        for tool in tools {
            let name = tool.name
            precondition(table[name] == nil, "AIToolRouter: duplicate tool name '\(name)'")
            table[name] = tool
            let tty = type(of: tool)
            let meta = ToolMetadata(agentSafe: tty.agentSafe, verbClass: tty.verbClass)
            metadata[name] = meta
            manifest.append(tool.definition)
            if meta.agentSafe {
                externalManifest.append(tool.definition)
            }
        }
        self.table = table
        self.metadata = metadata
        self.manifest = manifest
        self.externalManifest = externalManifest
        self.auditSink = auditSink
        self.autoApplyHook = autoApplyHook
        self.dispatchCeilingOverride = dispatchCeilingOverride
        self.onDispatchStart = onDispatchStart
    }

    /// Manifest as seen by an external (MCP) client. Filters out tools
    /// flagged `agentSafe: false`.
    public func externalManifestList() -> [AIToolDefinition] {
        externalManifest
    }

    /// Manifest including user-only tools — for in-app surfaces.
    public func fullManifestList() -> [AIToolDefinition] {
        manifest
    }

    /// Hard per-dispatch ceiling by verb class. Deliberately ABOVE every
    /// inner watchdog (`withToolTimeout` reads top out at 120s,
    /// `withApplierTimeout` writes at 600s) so the inner, better-worded
    /// timeouts fire first; this is the backstop for work that ignores
    /// cancellation and defeats the task-group-based watchdogs.
    static func dispatchCeiling(for verbClass: VerbClass) -> TimeInterval {
        switch verbClass {
        case .read, .viewState, .proposalLifecycle, .undo:
            return 150
        case .semanticWrite, .destructive:
            return 660
        }
    }

    /// Run a tool. The bridge is expected to map a JSON-RPC `tools/call`
    /// onto this method.
    ///
    /// Bounded by a HARD wall-clock deadline (`dispatchCeiling`): at the
    /// deadline the caller gets a typed `backendError` immediately, the
    /// tool task is cancelled and orphaned, and the server stays
    /// responsive. Without this, a non-cancellable wedge (stalled mmap
    /// read, CPU-bound render) held the serve loop for minutes and every
    /// queued request timed out client-side (2026-07-21 Mac QA, F5).
    public func dispatch(
        name: String,
        rawArguments: Data,
        context: AIToolContext
    ) async -> ToolResult {
        // Pulse the "agent is working" indicator at dispatch START —
        // matching Windows — so the user sees activity during a slow or
        // ultimately-failing call, not only after it completes.
        if case .external = context.origin {
            onDispatchStart?(name, context.origin.label)
        }
        let verbClass = metadata[name]?.verbClass ?? .read
        let ceiling = dispatchCeilingOverride ?? Self.dispatchCeiling(for: verbClass)
        let deadlineHit = DeadlineFlag()
        let result = await withHardDeadline(
            seconds: ceiling,
            onDeadline: {
                deadlineHit.set()
                return ToolResult.failed(.backendError(
                    "\(name) exceeded the \(Int(ceiling))s dispatch deadline — the app-side operation was asked to cancel and may still be finishing in the background. The server stays responsive; check state with a read tool before retrying."))
            },
            work: { await self.dispatchInner(name: name, rawArguments: rawArguments, context: context) }
        )
        if deadlineHit.value {
            emitAudit(name: name, args: rawArguments, context: context,
                      outcome: .failed(tag: "dispatchDeadline"),
                      verbClass: verbClass,
                      durationMS: Int(ceiling * 1000))
        }
        return result
    }

    private func dispatchInner(
        name: String,
        rawArguments: Data,
        context: AIToolContext
    ) async -> ToolResult {
        let started = Date()

        guard let tool = table[name], let meta = metadata[name] else {
            let outcome = AuditOutcome.failed(tag: "unknownTool")
            emitAudit(name: name, args: rawArguments, context: context,
                      outcome: outcome, verbClass: .read,
                      durationMS: msSince(started))
            return .failed(.unknownTarget(name))
        }

        // External-access gate. User-only tools must not be called from
        // the bridge layer (the bridge is supposed to filter via the
        // external manifest, but defence in depth is cheap).
        if case .external = context.origin, !meta.agentSafe {
            let outcome = AuditOutcome.failed(tag: "notAgentSafe")
            emitAudit(name: name, args: rawArguments, context: context,
                      outcome: outcome, verbClass: meta.verbClass,
                      durationMS: msSince(started))
            return .failed(.unknownTarget(name))
        }

        let result = await tool.invoke(arguments: rawArguments, context: context)
        let durationMS = msSince(started)

        // Post-dispatch budget gate: writes must reserve a slot. If the
        // budget is exhausted, withdraw the proposal so the user's strip
        // is unaffected.
        switch result {
        case .data, .image:
            // Both are read-tool successes (image = inline bytes); neither needs
            // the write-budget gate.
            emitAudit(name: name, args: rawArguments, context: context,
                      outcome: .data, verbClass: meta.verbClass, durationMS: durationMS)
            return result

        case .proposed(let proposal):
            // viewState bypasses the budget by convention — view-state
            // tools should return `.data`, not `.proposed`.
            switch meta.verbClass {
            case .read, .viewState, .proposalLifecycle, .undo:
                // Doesn't apply — return as-is (these aren't supposed to
                // produce proposals, but if they do we don't gate them).
                emitAudit(name: name, args: rawArguments, context: context,
                          outcome: .proposed(proposal.id),
                          verbClass: meta.verbClass,
                          durationMS: durationMS)
                return result
            case .semanticWrite, .destructive:
                // Auto-apply path: if the host opts this proposal in,
                // run the apply synchronously and return success. The
                // budget gate is bypassed by design — auto-applied
                // writes don't pile up in the strip, so the original
                // "cap pending strip items" rationale doesn't apply.
                if let hook = autoApplyHook,
                   await hook.shouldAutoApply(meta.verbClass, proposal) {
                    do {
                        try await hook.apply(proposal.id)
                        emitAudit(name: name, args: rawArguments, context: context,
                                  outcome: .applied(proposal.id),
                                  verbClass: meta.verbClass,
                                  durationMS: msSince(started))
                        let ack = AutoAppliedAck(proposal: proposal)
                        let body = (try? JSONEncoder().encode(ack)) ?? Data()
                        return .data(body)
                    } catch {
                        // The applier threw — withdraw the optimistic
                        // proposal so a deterministically failing write
                        // can't linger in the queue only to fail again.
                        // Mirrors the budget-cap path below. Audit
                        // records the failure.
                        _ = await context.proposals.withdraw(proposal.id)
                        emitAudit(name: name, args: rawArguments, context: context,
                                  outcome: .failed(tag: "autoApplyFailed"),
                                  verbClass: meta.verbClass,
                                  durationMS: msSince(started))
                        return .failed(.backendError("auto-apply failed: \(error)"))
                    }
                }

                let accepted = await context.budget.tryAccept(origin: context.origin)
                if accepted {
                    emitAudit(name: name, args: rawArguments, context: context,
                              outcome: .proposed(proposal.id),
                              verbClass: meta.verbClass,
                              durationMS: durationMS)
                    return result
                } else {
                    _ = await context.proposals.withdraw(proposal.id)
                    emitAudit(name: name, args: rawArguments, context: context,
                              outcome: .failed(tag: "perTurnProposalCapExceeded"),
                              verbClass: meta.verbClass, durationMS: durationMS)
                    return .failed(.perTurnProposalCapExceeded(limit: context.budget.limit))
                }
            }

        case .failed(let reason):
            emitAudit(name: name, args: rawArguments, context: context,
                      outcome: .failed(tag: reason.auditTag),
                      verbClass: meta.verbClass, durationMS: durationMS)
            return result
        }
    }

    // MARK: - Internals

    private func emitAudit(
        name: String,
        args: Data,
        context: AIToolContext,
        outcome: AuditOutcome,
        verbClass: VerbClass,
        durationMS: Int
    ) {
        let entry = AuditEntry(
            requestID: context.requestID,
            origin: AuditOrigin.from(context.origin),
            originLabel: context.origin.label,
            toolName: name,
            verbClass: verbClass,
            outcome: outcome,
            durationMS: durationMS,
            payloadHash: AuditEntry.payloadHash(of: args)
        )
        auditSink.record(entry)
    }

    private func msSince(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000.0)
    }
}

/// Lock-guarded flag set from the deadline racer (off-actor) and read
/// back on the router after the race resolves.
private final class DeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
