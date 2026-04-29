// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// List the user's recent searches (form-snapshot based, persisted on disk).
struct ListRecentSearchesTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let entries: [Entry]
        struct Entry: Encodable, Sendable {
            let id: String
            let name: String
            let savedAtISO: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_recent_searches",
        description: "List the user's recent searches (most-recent first). Each entry is a saved form snapshot.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> [(id: UUID, name: String, savedAt: Date)]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let entries = await snapshot().map {
            Output.Entry(
                id: $0.id.uuidString,
                name: $0.name,
                savedAtISO: iso.string(from: $0.savedAt)
            )
        }
        return Output(entries: entries)
    }
}
