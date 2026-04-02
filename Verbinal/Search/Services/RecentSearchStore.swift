// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log

@Observable
final class RecentSearchStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "RecentSearches")
    private let maxEntries = 20
    private let fileName: String
    private(set) var searches: [RecentSearch] = []

    init(fileName: String = "recent_searches.json") {
        self.fileName = fileName
        searches = readFromDisk()
    }

    func save(_ search: RecentSearch) {
        // Dedup by snapshot content — update if same filters exist
        if let idx = searches.firstIndex(where: { $0.formSnapshot == search.formSnapshot }) {
            searches.remove(at: idx)
        }

        var updated = search
        updated.savedAt = Date()
        searches.insert(updated, at: 0)

        if searches.count > maxEntries {
            searches = Array(searches.prefix(maxEntries))
        }

        writeToDisk()
    }

    func remove(_ search: RecentSearch) {
        searches.removeAll { $0.id == search.id }
        writeToDisk()
    }

    func rename(_ search: RecentSearch, to newName: String) {
        if let idx = searches.firstIndex(where: { $0.id == search.id }) {
            searches[idx].name = newName
            writeToDisk()
        }
    }

    func clear() {
        searches.removeAll()
        writeToDisk()
    }

    // MARK: - Persistence

    private var fileURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func readFromDisk() -> [RecentSearch] {
        guard let url = fileURL else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RecentSearch].self, from: data)
        } catch {
            Self.logger.warning("Read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func writeToDisk() {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(searches)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
