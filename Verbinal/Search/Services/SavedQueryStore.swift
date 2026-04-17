// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log

@Observable
final class SavedQueryStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "SavedQueries")
    private let maxEntries = 20
    private let persistence: DiskPersistence<[SavedQuery]>
    private(set) var queries: [SavedQuery] = []

    init(fileName: String = "saved_queries.json") {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger
        )
        self.queries = persistence.read() ?? []
    }

    func save(_ query: SavedQuery) {
        var updated = query
        updated.savedAt = Date()
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
}
