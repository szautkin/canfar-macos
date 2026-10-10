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
            /// Run from the ADQL editor; `load_recent_search` puts it back there.
            let fromEditor: Bool
            let adql: String?
        }
    }

    /// One recent search as the tool reads it.
    struct Row: Sendable {
        let id: UUID
        let name: String
        let savedAt: Date
        let adql: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_recent_searches",
        description: "List the user's recent searches (most-recent first). Each is a form search, or — `fromEditor: true`, with its `adql` — a query run from the ADQL editor, which `load_recent_search` puts back into the editor.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> [Row]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let entries = await snapshot().map {
            Output.Entry(
                id: $0.id.uuidString,
                name: $0.name,
                savedAtISO: iso.string(from: $0.savedAt),
                fromEditor: $0.adql != nil,
                adql: $0.adql
            )
        }
        return Output(entries: entries)
    }
}
