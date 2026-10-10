// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// List the user's saved ADQL queries.
struct ListSavedQueriesTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let entries: [Entry]
        struct Entry: Encodable, Sendable {
            let id: String
            let name: String
            let savedAtISO: String
            /// First line of the ADQL for preview.
            let preview: String
            /// Free-form rationale (may be empty for hand-saved queries
            /// from before F-6 shipped).
            let description: String
            let tags: [String]
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_saved_queries",
        description: "List saved ADQL queries (id, name, first-line preview, savedAt, description, tags).",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> [SavedQueryRow]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let entries = await snapshot().map {
            Output.Entry(
                id: $0.id.uuidString,
                name: $0.name,
                savedAtISO: iso.string(from: $0.savedAt),
                preview: String($0.adql.split(separator: "\n", maxSplits: 1).first ?? ""),
                description: $0.description,
                tags: $0.tags
            )
        }
        return Output(entries: entries)
    }
}

/// Flat row used by both list_saved_queries and get_saved_query so the
/// AppState wiring constructs one shape and both tools consume it.
struct SavedQueryRow: Sendable {
    let id: UUID
    let name: String
    let adql: String
    let savedAt: Date
    let description: String
    let tags: [String]
}

/// Get the full record of one saved query by id.
struct GetSavedQueryTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Output: Encodable, Sendable {
        let id: String
        let name: String
        let adql: String
        let savedAtISO: String
        let description: String
        let tags: [String]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_saved_query",
        description: "Fetch the full record of one saved query by id (ADQL + description + tags).",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": {
            "id": { "type": "string", "description": "UUID string of the saved query." }
          },
          "additionalProperties": false
        }
        """#
    )

    let lookup: @Sendable (_ id: UUID) async -> SavedQueryRow?

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard let uuid = UUID(uuidString: args.id) else {
            throw ToolFailureReason.invalidArgument("id is not a UUID")
        }
        guard let row = await lookup(uuid) else {
            throw ToolFailureReason.unknownTarget("saved_query \(args.id)")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return Output(
            id: row.id.uuidString,
            name: row.name,
            adql: row.adql,
            savedAtISO: iso.string(from: row.savedAt),
            description: row.description,
            tags: row.tags
        )
    }
}
