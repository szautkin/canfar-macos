// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - save_query

/// Save a new ADQL query under a friendly name.
struct SaveQueryTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let name: String
        let adql: String
        var description: String?
        var tags: [String]?
    }

    /// Encoded as the proposal payload; the applier reads it back.
    struct Payload: Codable, Sendable {
        let name: String
        let adql: String
        let description: String
        let tags: [String]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "save_query",
        description: "Save an ADQL query under a name. Strongly encouraged: include a `description` explaining why the query matters and tags grouping it with related work — six months from now you'll thank yourself. Persisted immediately when auto-apply is on; otherwise queues to the proposal strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["name", "adql"],
          "properties": {
            "name":        { "type": "string", "minLength": 1 },
            "adql":        { "type": "string", "minLength": 1 },
            "description": { "type": "string", "description": "Free-form rationale: why this query matters." },
            "tags":        { "type": "array", "items": { "type": "string" } }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolFailureReason.invalidArgument("name is empty")
        }
        guard !args.adql.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolFailureReason.invalidArgument("adql is empty")
        }
        return try ProposalPlan.encoding(
            kind: "save_query",
            summary: "Save query: \(args.name)",
            payload: Payload(
                name: args.name,
                adql: args.adql,
                description: args.description ?? "",
                tags: args.tags ?? []
            )
        )
    }
}

// MARK: - update_saved_query

/// Update an existing saved query's name and/or ADQL.
struct UpdateSavedQueryTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let id: String
        var name: String?
        var adql: String?
        var description: String?
        var tags: [String]?
    }

    struct Payload: Codable, Sendable {
        let id: String
        let name: String?
        let adql: String?
        let description: String?
        let tags: [String]?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "update_saved_query",
        description: "Update an existing saved query (by id). Any of `name`, `adql`, `description`, `tags` may be provided; at least one must be present. Omitted fields are left unchanged.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": {
            "id":          { "type": "string" },
            "name":        { "type": "string" },
            "adql":        { "type": "string" },
            "description": { "type": "string" },
            "tags":        { "type": "array", "items": { "type": "string" } }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let hasAny = !(args.name?.isEmpty ?? true)
            || !(args.adql?.isEmpty ?? true)
            || args.description != nil
            || args.tags != nil
        if !hasAny {
            throw ToolFailureReason.invalidArgument("provide at least one of: name, adql, description, tags")
        }
        guard UUID(uuidString: args.id) != nil else {
            throw ToolFailureReason.invalidArgument("id is not a UUID")
        }
        return try ProposalPlan.encoding(
            kind: "update_saved_query",
            summary: "Update saved query \(args.id)",
            payload: Payload(
                id: args.id,
                name: args.name,
                adql: args.adql,
                description: args.description,
                tags: args.tags
            )
        )
    }
}

// MARK: - delete_saved_query (destructive)

struct DeleteSavedQueryTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Payload: Codable, Sendable {
        let id: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_saved_query",
        description: "Permanently delete a saved query by id. Destructive — runs immediately when auto-apply is on (the user has opted into autonomous deletion); otherwise queues for explicit confirmation in the strip.",
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
            kind: "delete_saved_query",
            summary: "Delete saved query \(args.id)",
            payload: Payload(id: args.id)
        )
    }
}

// MARK: - Appliers

/// Concrete handler that runs when the user clicks Apply on a
/// `save_query` proposal in the strip.
struct SaveQueryApplier: ProposalApplier {
    let kind = "save_query"
    let store: SavedQueryStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(SaveQueryTool.Payload.self, from: proposal.payload)
        let attribution = AgentAttribution.from(proposal: proposal)
        let query = SavedQuery(
            name: payload.name,
            adql: payload.adql,
            description: payload.description,
            tags: payload.tags,
            agentAttribution: attribution
        )
        await MainActor.run {
            store.save(query)
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

struct UpdateSavedQueryApplier: ProposalApplier {
    let kind = "update_saved_query"
    let store: SavedQueryStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(UpdateSavedQueryTool.Payload.self, from: proposal.payload)
        guard let id = UUID(uuidString: payload.id) else {
            throw ProposalApplyError.backendError("invalid id")
        }
        try await MainActor.run {
            guard var existing = store.queries.first(where: { $0.id == id }) else {
                throw ProposalApplyError.backendError("saved query not found: \(id)")
            }
            if let name = payload.name { existing.name = name }
            if let adql = payload.adql { existing.adql = adql }
            if let description = payload.description { existing.description = description }
            if let tags = payload.tags { existing.tags = tags }
            existing.agentAttribution = AgentAttribution.from(proposal: proposal)
            store.save(existing)
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

struct DeleteSavedQueryApplier: ProposalApplier {
    let kind = "delete_saved_query"
    let store: SavedQueryStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DeleteSavedQueryTool.Payload.self, from: proposal.payload)
        guard let id = UUID(uuidString: payload.id) else {
            throw ProposalApplyError.backendError("invalid id")
        }
        try await MainActor.run {
            guard let existing = store.queries.first(where: { $0.id == id }) else {
                throw ProposalApplyError.backendError("saved query not found: \(id)")
            }
            store.remove(existing)
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}
