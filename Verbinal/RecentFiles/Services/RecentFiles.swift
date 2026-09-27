// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// A recently opened file — a security-scoped bookmark, so a sandboxed app
/// can open it again after a relaunch.
struct RecentFile: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let bookmark: Data
    var id: String { path }
}

/// The files a viewer opened lately, newest first — one kind per viewer,
/// one store and one list for all of them.
@Observable
@MainActor
final class RecentFiles {
    static let fits = RecentFiles(key: "fitsViewer.recents")
    /// The key the cube viewer's recents were always kept under.
    static let cubes = RecentFiles(key: "cubeViewer.recents")

    static let limit = 8

    private(set) var items: [RecentFile]
    private let key: String
    private let defaults: UserDefaults

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        items = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RecentFile].self, from: $0) } ?? []
    }

    /// Remembers `url` at the top; a file whose bookmark cannot be made is not.
    func add(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        items.removeAll { $0.path == url.path }
        items.insert(RecentFile(name: url.lastPathComponent, path: url.path, bookmark: bookmark), at: 0)
        items = Array(items.prefix(Self.limit))
        save()
    }

    /// The file again, or nil — and it is forgotten — when it is gone.
    func resolve(_ recent: RecentFile) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark, options: Self.resolveOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else {
            remove(recent)
            return nil
        }
        return url
    }

    func remove(_ recent: RecentFile) {
        items.removeAll { $0.id == recent.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }

    #if os(macOS)
    private static let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif
}
