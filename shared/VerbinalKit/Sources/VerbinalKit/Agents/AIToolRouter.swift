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

    public init(
        tools: [any AITool],
        auditSink: any AuditSink = LoggingAuditSink()
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

    /// Run a tool. The bridge is expected to map a JSON-RPC `tools/call`
    /// onto this method.
    public func dispatch(
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
        case .data:
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
