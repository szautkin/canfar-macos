// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

// `@MainActor` so the @Sendable MCP applier structs holding this
// store no longer trip strict-concurrency warnings, and the SwiftUI
// bindings reading `queries` get the actor isolation they expect.
@Observable
@MainActor
final class SavedQueryStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "SavedQueries")
    private let maxEntries = 20
    private let persistence: DiskPersistence<[SavedQuery]>
    private(set) var queries: [SavedQuery] = []

    /// v2: one row per query, text as typed. Files written before it can
    /// hold several rows for one query (every update added a row) and
    /// `&amp;` where the person typed `&`.
    private static let schemaVersion = 2

    init(fileName: String = "saved_queries.json") {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger,
            schemaVersion: Self.schemaVersion
        )
        self.queries = persistence.read(migrating: Self.migrate) ?? []
    }

    /// Saves a new query, or replaces the one with its id; either way it is
    /// the newest.
    func save(_ query: SavedQuery) {
        var updated = query
        updated.savedAt = Date()
        queries.removeAll { $0.id == query.id }
        queries.insert(updated, at: 0)
        if queries.count > maxEntries {
            queries = Array(queries.prefix(maxEntries))
        }
        persistence.write(queries)
    }

    func remove(_ query: SavedQuery) {
        queries.removeAll { $0.id == query.id }
        persistence.write(queries)
    }

    func rename(_ query: SavedQuery, to newName: String) {
        if let idx = queries.firstIndex(where: { $0.id == query.id }) {
            queries[idx].name = newName
            persistence.write(queries)
        }
    }

    func clear() {
        queries.removeAll()
        persistence.write(queries)
    }

    /// Brings a v1 file to v2: the newest row of each query, its `&amp;`
    /// unescaped once.
    private nonisolated static func migrate(_ rows: [SavedQuery], from version: Int) -> [SavedQuery] {
        var seen = Set<UUID>()
        let newest = rows.sorted { $0.savedAt > $1.savedAt }.filter { seen.insert($0.id).inserted }
        return newest.map { row in
            var row = row
            row.name = unescaped(row.name)
            row.description = unescaped(row.description)
            row.tags = row.tags.map(unescaped)
            row.agentAttribution = row.agentAttribution.map {
                AgentAttribution(proposalID: $0.proposalID, originFingerprint: $0.originFingerprint,
                                 originLabel: $0.originLabel, appliedAt: $0.appliedAt, summary: unescaped($0.summary))
            }
            return row
        }
    }

    private nonisolated static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
    }
}
