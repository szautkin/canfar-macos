// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

/// Persists coordinate bookmarks for the FITS viewer.
@Observable
@MainActor
final class BookmarkStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Bookmarks")
    private let persistence: DiskPersistence<[CoordinateBookmark]>
    private(set) var bookmarks: [CoordinateBookmark] = []

    /// Where each bookmark saved, renamed or deleted is recorded (plan 23 C).
    private let changes: ChangeLog

    init(fileName: String = "bookmarks.json", changes: ChangeLog = .shared) {
        self.changes = changes
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal/Bookmarks",
            fileName: fileName,
            logger: Self.logger
        )
        self.bookmarks = persistence.read() ?? []
    }

    /// The bookmarks kept with the file at `url`: by its identity, which
    /// every device shares for a file of Research or of the person's storage
    /// (plan 36 4.2), or by its path here, as before.
    func bookmarks(for url: URL) -> [CoordinateBookmark] {
        let identity = FileOrigins.shared.identity(of: url)
        let paths: Set<String> = [identity, url.path, FileIdentity.key(url)]
        return bookmarks.filter { paths.contains($0.sourceFilePath) }
    }

    // MARK: - From another device (plan 36 4.2)

    /// The bookmarks every device can use: of a file every device knows, or
    /// of no file.
    var portable: [CoordinateBookmark] {
        bookmarks.filter { $0.sourceFilePath.isEmpty || FileOrigins.isPortable($0.sourceFilePath) }
    }

    /// Keeps `bookmark` as another device has it, in its place by when it was saved.
    func keep(_ bookmark: CoordinateBookmark) {
        let isNew = !bookmarks.contains { $0.id == bookmark.id }
        bookmarks.removeAll { $0.id == bookmark.id }
        bookmarks = (bookmarks + [bookmark]).sorted { $0.savedAt > $1.savedAt }
        persistence.write(bookmarks)
        changes.done(isNew ? "save_fits_bookmark" : "rename_fits_bookmark", "the sky bookmark \"\(bookmark.label)\"")
    }

    func remove(id: UUID) {
        if let bookmark = bookmarks.first(where: { $0.id == id }) { delete(bookmark) }
    }

    func save(_ bookmark: CoordinateBookmark) {
        bookmarks.insert(bookmark, at: 0)
        persistence.write(bookmarks)
        changes.done("save_fits_bookmark", "the sky bookmark \"\(bookmark.label)\"")
    }

    func delete(_ bookmark: CoordinateBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistence.write(bookmarks)
        changes.done("delete_fits_bookmark", "the sky bookmark \"\(bookmark.label)\"")
    }

    func rename(_ bookmark: CoordinateBookmark, label: String) {
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx].label = label
            persistence.write(bookmarks)
            changes.done("rename_fits_bookmark", "the sky bookmark \"\(bookmark.label)\" to \"\(label)\"")
        }
    }
}
