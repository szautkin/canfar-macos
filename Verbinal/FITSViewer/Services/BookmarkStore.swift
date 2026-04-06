// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log

/// Persists coordinate bookmarks for the FITS viewer.
@Observable
final class BookmarkStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Bookmarks")
    private let fileName: String
    private(set) var bookmarks: [CoordinateBookmark] = []

    init(fileName: String = "bookmarks.json") {
        self.fileName = fileName
        bookmarks = readFromDisk()
    }

    /// Bookmarks for a specific file.
    func bookmarks(for filePath: String) -> [CoordinateBookmark] {
        bookmarks.filter { $0.sourceFilePath == filePath }
    }

    func save(_ bookmark: CoordinateBookmark) {
        bookmarks.insert(bookmark, at: 0)
        writeToDisk()
    }

    func delete(_ bookmark: CoordinateBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        writeToDisk()
    }

    func rename(_ bookmark: CoordinateBookmark, label: String) {
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx].label = label
            writeToDisk()
        }
    }

    // MARK: - Persistence

    private var fileURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal/Bookmarks", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func readFromDisk() -> [CoordinateBookmark] {
        guard let url = fileURL else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CoordinateBookmark].self, from: data)
        } catch {
            return []
        }
    }

    private func writeToDisk() {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(bookmarks)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Bookmark write failed: \(error.localizedDescription)")
        }
    }
}
