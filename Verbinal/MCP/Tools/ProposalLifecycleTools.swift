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
            let originTag: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_pending_proposals",
        description: "List proposals currently waiting for user review in the strip. Returns id, the tool that created it, kind, summary, and origin.",
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
        let items = pending.map { p in
            Output.Item(
                id: p.id.uuidString,
                toolName: p.toolName,
                kind: p.kind,
                summary: p.summary,
                createdAtISO: iso.string(from: p.createdAt),
                originTag: AuditOrigin.from(p.origin).tag
            )
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
        let id: String
    }

    struct Output: Encodable, Sendable {
        let id: String
        let state: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_proposal_state",
        description: "Look up the lifecycle state of a proposal by id (pending, applied, rejected, withdrawn, unknown). Tombstones live ~5 min after resolution.",
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
        let state = await context.proposals.state(uuid)
        do {
            let bytes = try JSONEncoder().encode(Output(id: args.id, state: state.rawValue))
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
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "withdraw_proposal",
        description: "Retract one of your own pending proposals. Use when you realised mid-flow that the proposal was wrong; the user no longer sees it in the strip.",
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
        let didWithdraw = await context.proposals.withdraw(uuid)
        do {
            let bytes = try JSONEncoder().encode(Output(id: args.id, withdrew: didWithdraw))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
