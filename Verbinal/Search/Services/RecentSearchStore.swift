// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

// `@MainActor` to match SavedQueryStore: the @Sendable MCP applier structs
// hold this store, and the @Observable state must mutate on the main actor.
@Observable
@MainActor
final class RecentSearchStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "RecentSearches")
    private let maxEntries = 20
    private let persistence: DiskPersistence<[RecentSearch]>
    private(set) var searches: [RecentSearch] = []

    /// Where the person's changes to the list are recorded (plan 23 C). A
    /// search joining it is the app's bookkeeping, not a change.
    private let changes: ChangeLog

    init(fileName: String = "recent_searches.json", changes: ChangeLog = .shared) {
        self.changes = changes
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger
        )
        self.searches = persistence.read() ?? []
    }

    func save(_ search: RecentSearch) {
        if let idx = searches.firstIndex(where: { $0.formSnapshot == search.formSnapshot }) {
            searches.remove(at: idx)
        }
        var updated = search
        updated.savedAt = Date()
        searches.insert(updated, at: 0)
        if searches.count > maxEntries {
            searches = Array(searches.prefix(maxEntries))
        }
        persistence.write(searches)
    }

    func remove(_ search: RecentSearch) {
        searches.removeAll { $0.id == search.id }
        persistence.write(searches)
        changes.done("remove_recent_search", "the recent search \"\(search.name)\"")
    }

    func rename(_ search: RecentSearch, to newName: String) {
        if let idx = searches.firstIndex(where: { $0.id == search.id }) {
            searches[idx].name = newName
            persistence.write(searches)
            changes.done("rename_recent_search", "the recent search \"\(search.name)\" to \"\(newName)\"")
        }
    }

    func clear() {
        let count = searches.count
        searches.removeAll()
        persistence.write(searches)
        changes.done("clear_recent_searches", "the recent searches (\(count))")
    }
}
