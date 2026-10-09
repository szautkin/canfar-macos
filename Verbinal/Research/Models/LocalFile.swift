// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A file Research keeps on this computer: where it is, and the
/// security-scoped bookmark that lets the sandbox open it again on a later
/// launch. The one way a record's main file and each of its other files
/// (plan 34 F) are reached.
struct LocalFile: Equatable, Sendable {
    /// The path, relative to Downloads or absolute; empty for none.
    var path: String
    var bookmarkData: Data?

    var isEmpty: Bool { path.isEmpty }

    /// The file's URL; nil without a file. Prefers a sandbox-readable
    /// candidate (tilde expansion, container ↔ user-facing Downloads).
    /// Never the empty path, which is the working directory.
    var url: URL? {
        guard !isEmpty else { return nil }
        return readableURL ?? URL(fileURLWithPath: expandedPath)
    }

    /// The file's name; empty without a file.
    var name: String { url?.lastPathComponent ?? "" }

    /// The file is there — found through its bookmark or at its path.
    var exists: Bool {
        withReadable { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// What is wrong with the file — missing, unreadable, empty, an empty
    /// archive — or nil when it holds something, or there is no file.
    var problem: DownloadedFileCheck.Problem? {
        guard !isEmpty else { return nil }
        return withReadable { DownloadedFileCheck.problem(at: $0) } ?? .missing
    }

    /// The file through its bookmark, and whether the bookmark wants
    /// renewing; nil without one, or when it no longer resolves.
    func bookmarked() -> (url: URL, stale: Bool)? {
        #if os(macOS)
        guard let bookmarkData else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
        #else
        return nil
        #endif
    }

    /// Runs `body` on the file, opened as Verbinal may open it: through its
    /// bookmark first (with the access that grants), else at its path. Nil
    /// when there is no file to open.
    func withReadable<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard !isEmpty else { return nil }
        if let bookmarked = bookmarked()?.url, bookmarked.startAccessingSecurityScopedResource() {
            defer { bookmarked.stopAccessingSecurityScopedResource() }
            return try body(bookmarked)
        }
        guard let url = readableURL else { return nil }
        return try body(url)
    }

    /// First existing file URL for `path`, or nil when none of the
    /// sandbox/tilde candidates exist. The bookmark is separate.
    var readableURL: URL? {
        guard !isEmpty else { return nil }
        #if os(macOS)
        return LocalFolderAccessStore.readableURL(for: path, directory: false)
        #else
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return URL(fileURLWithPath: expandedPath)
        #endif
    }

    private var expandedPath: String {
        #if os(macOS)
        return LocalFolderAccessStore.expandedPath(path)
        #else
        return (path as NSString).expandingTildeInPath
        #endif
    }
}
