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
    private let fileName: String
    private(set) var queries: [SavedQuery] = []

    init(fileName: String = "saved_queries.json") {
        self.fileName = fileName
        queries = readFromDisk()
    }

    func save(_ query: SavedQuery) {
        var updated = query
        updated.savedAt = Date()
        queries.insert(updated, at: 0)

        if queries.count > maxEntries {
            queries = Array(queries.prefix(maxEntries))
        }

        writeToDisk()
    }

    func remove(_ query: SavedQuery) {
        queries.removeAll { $0.id == query.id }
        writeToDisk()
    }

    func rename(_ query: SavedQuery, to newName: String) {
        if let idx = queries.firstIndex(where: { $0.id == query.id }) {
            queries[idx].name = newName
            writeToDisk()
        }
    }

    func clear() {
        queries.removeAll()
        writeToDisk()
    }

    // MARK: - Persistence

    private var fileURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func readFromDisk() -> [SavedQuery] {
        guard let url = fileURL else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([SavedQuery].self, from: data)
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
            let data = try encoder.encode(queries)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
