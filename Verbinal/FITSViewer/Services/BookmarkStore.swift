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
@MainActor
final class BookmarkStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Bookmarks")
    private let persistence: DiskPersistence<[CoordinateBookmark]>
    private(set) var bookmarks: [CoordinateBookmark] = []

    init(fileName: String = "bookmarks.json") {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal/Bookmarks",
            fileName: fileName,
            logger: Self.logger
        )
        self.bookmarks = persistence.read() ?? []
    }

    /// Bookmarks for a specific file.
    func bookmarks(for filePath: String) -> [CoordinateBookmark] {
        bookmarks.filter { $0.sourceFilePath == filePath }
    }

    func save(_ bookmark: CoordinateBookmark) {
        bookmarks.insert(bookmark, at: 0)
        persistence.write(bookmarks)
    }

    func delete(_ bookmark: CoordinateBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistence.write(bookmarks)
    }

    func rename(_ bookmark: CoordinateBookmark, label: String) {
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx].label = label
            persistence.write(bookmarks)
        }
    }
}
