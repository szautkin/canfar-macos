// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

struct RecentNotebookEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let path: String
    let name: String
    let openedAt: Date

    init(url: URL) {
        self.id = UUID()
        self.path = url.path
        self.name = url.lastPathComponent
        self.openedAt = Date()
    }
}

@Observable
final class RecentNotebooksService {
    private static let logger = Logger(subsystem: "com.codebg.VerbinalPi", category: "RecentNotebooks")
    private let maxEntries = 15
    private let persistence: DiskPersistence<[RecentNotebookEntry]>
    private(set) var entries: [RecentNotebookEntry] = []

    init(fileName: String = "recent-notebooks.json") {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal/Notebook",
            fileName: fileName,
            logger: Self.logger
        )
        self.entries = persistence.read() ?? []
    }

    func add(url: URL) {
        entries.removeAll { $0.path == url.path }
        entries.insert(RecentNotebookEntry(url: url), at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persistence.write(entries)
    }

    func remove(_ entry: RecentNotebookEntry) {
        entries.removeAll { $0.id == entry.id }
        persistence.write(entries)
    }

    func clear() {
        entries.removeAll()
        persistence.write(entries)
    }
}
