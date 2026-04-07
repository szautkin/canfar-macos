// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log

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
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "RecentNotebooks")
    private let maxEntries = 15
    private let fileName: String
    private(set) var entries: [RecentNotebookEntry] = []

    init(fileName: String = "recent-notebooks.json") {
        self.fileName = fileName
        entries = readFromDisk()
    }

    func add(url: URL) {
        // Remove existing entry for same path
        entries.removeAll { $0.path == url.path }
        entries.insert(RecentNotebookEntry(url: url), at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        writeToDisk()
    }

    func remove(_ entry: RecentNotebookEntry) {
        entries.removeAll { $0.id == entry.id }
        writeToDisk()
    }

    func clear() {
        entries.removeAll()
        writeToDisk()
    }

    // MARK: - Persistence

    private var fileURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal/Notebook", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func readFromDisk() -> [RecentNotebookEntry] {
        guard let url = fileURL else { return [] }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RecentNotebookEntry].self, from: data)
        } catch { return [] }
    }

    private func writeToDisk() {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Write failed: \(error.localizedDescription)")
        }
    }
}
