// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// AI Guide management tools — the AI Guide screen's actions as tools
/// (Windows parity). An agent re-wording its own tool surface is a
/// meaningful act, so every mutation here is proposal-gated like any
/// other write: with auto-apply off the user approves each change in
/// the strip; guide names are validated against the live tool table so
/// a guide can never shadow a built-in tool.

// MARK: - list_guide_tools

struct ListGuideToolsTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let entries: [Entry]
        struct Entry: Encodable, Sendable {
            let id: String
            let name: String
            let description: String
            let hasBody: Bool
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_guide_tools",
        description: "List the user-authored AI Guide tools (stored instruction snippets exposed to agents as read-only tools): id, name, description, and whether a body is stored.",
        schema: #"""
        { "type": "object", "properties": {}, "additionalProperties": false }
        """#
    )

    let snapshot: @Sendable () async -> [Output.Entry]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        Output(entries: await snapshot())
    }
}

// MARK: - set_tool_description / clear_tool_description

struct SetToolDescriptionTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let toolName: String
        let description: String
    }
    struct Payload: Codable, Sendable {
        let toolName: String
        let description: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_tool_description",
        description: "Override how another tool is advertised in tools/list (the AI Guide's per-tool 'Your description'). The override applies on the agent's next tools/list. Proposal-gated; the tool must exist.",
        schema: #"""
        {
          "type": "object",
          "required": ["toolName", "description"],
          "properties": {
            "toolName": { "type": "string", "description": "Exact name of an existing tool." },
            "description": { "type": "string", "description": "Replacement description text." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let name = args.toolName.trimmingCharacters(in: .whitespaces)
        let desc = args.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolFailureReason.invalidArgument("toolName is empty") }
        guard !desc.isEmpty else { throw ToolFailureReason.invalidArgument("description is empty") }
        return try ProposalPlan.encoding(
            kind: "set_tool_description",
            summary: "Override the advertised description of '\(name)'",
            payload: Payload(toolName: name, description: desc)
        )
    }
}

struct ClearToolDescriptionTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable { let toolName: String }
    struct Payload: Codable, Sendable { let toolName: String }

    let definition = AIToolDefinition.withStaticSchema(
        name: "clear_tool_description",
        description: "Revert a tool's advertised description to its built-in default (removes the AI Guide override). Proposal-gated.",
        schema: #"""
        {
          "type": "object",
          "required": ["toolName"],
          "properties": { "toolName": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let name = args.toolName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ToolFailureReason.invalidArgument("toolName is empty") }
        return try ProposalPlan.encoding(
            kind: "clear_tool_description",
            summary: "Revert '\(name)' to its built-in description",
            payload: Payload(toolName: name)
        )
    }
}

// MARK: - add / update / delete guide tools

struct AddGuideToolTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let name: String
        let description: String
        let body: String?
    }
    struct Payload: Codable, Sendable {
        let name: String
        let description: String
        let body: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "add_guide_tool",
        description: "Create a read-only 'guide' tool that stores instructions for future agent sessions (name, description, optional body returned when the guide is invoked). Names must not collide with built-in tools. Proposal-gated.",
        schema: #"""
        {
          "type": "object",
          "required": ["name", "description"],
          "properties": {
            "name": { "type": "string", "description": "snake_case tool name for the guide." },
            "description": { "type": "string" },
            "body": { "type": "string", "description": "Text returned when the guide tool is called." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let name = args.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ToolFailureReason.invalidArgument("name is empty") }
        guard !args.description.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolFailureReason.invalidArgument("description is empty")
        }
        return try ProposalPlan.encoding(
            kind: "add_guide_tool",
            summary: "Add guide tool '\(name)'",
            payload: Payload(name: name, description: args.description, body: args.body)
        )
    }
}

struct UpdateGuideToolTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let id: String
        let name: String
        let description: String
        let body: String?
    }
    struct Payload: Codable, Sendable {
        let id: String
        let name: String
        let description: String
        let body: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "update_guide_tool",
        description: "Update a user-authored guide tool by id (name, description, body — see list_guide_tools for ids). Proposal-gated.",
        schema: #"""
        {
          "type": "object",
          "required": ["id", "name", "description"],
          "properties": {
            "id": { "type": "string" },
            "name": { "type": "string" },
            "description": { "type": "string" },
            "body": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard UUID(uuidString: args.id) != nil else {
            throw ToolFailureReason.invalidArgument("id is not a UUID")
        }
        guard !args.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolFailureReason.invalidArgument("name is empty")
        }
        return try ProposalPlan.encoding(
            kind: "update_guide_tool",
            summary: "Update guide tool '\(args.name)'",
            payload: Payload(id: args.id, name: args.name, description: args.description, body: args.body)
        )
    }
}

struct DeleteGuideToolTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable { let id: String }
    struct Payload: Codable, Sendable { let id: String }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_guide_tool",
        description: "Permanently delete a user-authored guide tool by id. Destructive — runs immediately when auto-apply is on; otherwise queues for confirmation.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard UUID(uuidString: args.id) != nil else {
            throw ToolFailureReason.invalidArgument("id is not a UUID")
        }
        return try ProposalPlan.encoding(
            kind: "delete_guide_tool",
            summary: "Delete guide tool \(args.id)",
            payload: Payload(id: args.id)
        )
    }
}

// MARK: - Appliers

/// All five appliers delegate to a single injected mutation closure so the
/// MainActor `AIGuideService` calls (and the built-in-name shadow check)
/// live in one place in the AppState wiring.
struct AIGuideMutationApplier: ProposalApplier {
    let kind: String
    /// Decodes the payload itself (kind-specific) and performs the mutation.
    let mutate: @Sendable (PendingProposal) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        do {
            try await mutate(proposal)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("AI Guide update failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
