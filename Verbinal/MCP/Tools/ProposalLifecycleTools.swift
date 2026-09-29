// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Tools that operate on the proposal queue itself. verbClass =
/// `.proposalLifecycle` so the router doesn't budget-gate them — the
/// queue is the thing being managed, not a target of new mutations.

// MARK: - list_pending_proposals

struct ListPendingProposalsTool: AITool {
    static let verbClass: VerbClass = .proposalLifecycle
    static let agentSafe: Bool = true

    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let proposals: [Item]
        struct Item: Encodable, Sendable {
            let id: String
            let toolName: String
            let kind: String
            let summary: String
            let createdAtISO: String
            /// When it expires unapplied (`PendingProposal.lifetime` after it arrived).
            let expiresAtISO: String
            let originTag: String
            /// Why its last apply failed, when one did.
            let failureReason: String?
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_pending_proposals",
        description: "List proposals currently waiting for user review in the strip. Returns id, the tool that created it, kind, summary, origin, `failureReason` when its last apply failed, and `expiresAtISO` — a proposal nobody applies within 3 hours expires and leaves Pending.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let pending = await context.proposals.list(origin: nil)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var items: [Output.Item] = []
        for p in pending {
            items.append(Output.Item(
                id: p.id.uuidString,
                toolName: p.toolName,
                kind: p.kind,
                summary: p.summary,
                createdAtISO: iso.string(from: p.createdAt),
                expiresAtISO: iso.string(from: p.expiresAt),
                originTag: AuditOrigin.from(p.origin).tag,
                failureReason: await context.proposals.failureReason(p.id)
            ))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(proposals: items))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - get_proposal_state

struct GetProposalStateTool: AITool {
    static let verbClass: VerbClass = .proposalLifecycle
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let id: String?
        let proposalId: String?

        var resolvedID: String? {
            let raw = id ?? proposalId
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    struct Output: Encodable, Sendable {
        let id: String
        let state: String
        /// Why the last apply failed, while the state is `failed`.
        var failureReason: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_proposal_state",
        description: "Look up the lifecycle state of a proposal by `id` or `proposalId` (pending, applying, applied, rejected, withdrawn, failed, expired, unknown). `failed` means the last apply threw and the item is still in the strip for retry, with `failureReason` saying why; `expired` means nobody applied it within 3 hours, so it was not applied and has left Pending (remembered for a day). Other outcomes are remembered ~5 min.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "Proposal UUID." },
            "proposalId": { "type": "string", "description": "Alias of id (same UUID)." }
          },
          "additionalProperties": false
        }
        """#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        guard let raw = args.resolvedID else {
            return .failed(.invalidArgument("pass id or proposalId"))
        }
        guard let uuid = UUID(uuidString: raw) else {
            return .failed(.invalidArgument("id is not a UUID"))
        }
        let state = await context.proposals.state(uuid)
        let reason = state == .failed ? await context.proposals.failureReason(uuid) : nil
        do {
            let bytes = try JSONEncoder().encode(Output(id: raw, state: state.rawValue, failureReason: reason))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - withdraw_proposal

/// Agent retracts its own pending proposal. Same observable effect as
/// reject (gone from the strip, tombstone visible to get_proposal_state)
/// but a different audit category — withdrawn calls indicate the agent
/// self-corrected, vs. rejected calls indicate the user said no.
struct WithdrawProposalTool: AITool {
    static let verbClass: VerbClass = .proposalLifecycle
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Output: Encodable, Sendable {
        let id: String
        let withdrew: Bool
        /// Proposals this client may still make; a withdrawn one's slot is given back.
        let budgetRemaining: Int
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "withdraw_proposal",
        description: "Retract one of your own pending proposals. Only meaningful for a proposal still waiting in Pending — every destructive one, and any other while Auto-apply is off (with it on, other writes apply at once, leaving nothing to withdraw). Use when you realised mid-flow that the proposal was wrong; the user no longer sees it in the strip, and its slot in your proposal budget is given back (`budgetRemaining`). Returns withdrew=false if the id is unknown or already resolved.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        guard let uuid = UUID(uuidString: args.id) else {
            return .failed(.invalidArgument("id is not a UUID"))
        }
        let origin = await context.proposals.list(origin: nil).first { $0.id == uuid }?.origin
        let didWithdraw = await context.proposals.withdraw(uuid)
        if didWithdraw, let origin { await context.budget.release(origin: origin) }
        do {
            let bytes = try JSONEncoder().encode(Output(id: args.id, withdrew: didWithdraw,
                                                        budgetRemaining: await context.budget.remaining(for: context.origin)))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
