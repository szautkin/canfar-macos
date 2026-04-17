// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

@Observable
final class RecentSearchStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "RecentSearches")
    private let maxEntries = 20
    private let persistence: DiskPersistence<[RecentSearch]>
    private(set) var searches: [RecentSearch] = []

    init(fileName: String = "recent_searches.json") {
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
    }

    func rename(_ search: RecentSearch, to newName: String) {
        if let idx = searches.firstIndex(where: { $0.id == search.id }) {
            searches[idx].name = newName
            persistence.write(searches)
        }
    }

    func clear() {
        searches.removeAll()
        persistence.write(searches)
    }
}
