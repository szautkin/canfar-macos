// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
import Foundation
import Observation
import os.log

/// Persistent, security-scoped access to user-granted local FOLDERS.
///
/// The macOS App Sandbox gives the app `~/Downloads` (via the downloads
/// entitlement) and any file/folder the user picks in an `NSOpenPanel`
/// (powerbox), but NOT `~/Pictures`, `~/Documents`, or arbitrary trees —
/// enumerating those returns "you don't have permission" (2026-07-21 Mac
/// QA, F14). This store lets the user grant a folder once via a picker
/// and remembers it across launches with an app-scoped security bookmark
/// (`com.apple.security.files.bookmarks.app-scope`, already entitled).
///
/// Reuses the proven pattern from `MCPIntegrationSettingsService`
/// (grant Claude's config folder) — generalized to a list of user-data
/// folders that the file browser AND the agent's `list_local_folder` /
/// `open_local_file` tools both resolve through.
///
/// Granted scopes are started once at launch and held for the whole app
/// run (the standard idiom for persistent folder access); there is no
/// matching stop until the process exits.
@Observable
@MainActor
final class LocalFolderAccessStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "FolderAccess")
    private static let defaultsKey = "com.codebg.Verbinal.localFolderBookmarks"

    /// Folders the user has granted, resolved and with scope held open.
    private(set) var grantedRoots: [URL] = []

    /// Raw bookmarks, kept so we can re-persist (dropping stale ones).
    private var bookmarks: [Data]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bookmarks = (defaults.array(forKey: Self.defaultsKey) as? [Data]) ?? []
        resolveAll()
    }

    /// `~/Downloads` — always readable via the downloads entitlement, no
    /// bookmark required. Included in access checks so the browser and
    /// tools treat it as granted. `nonisolated` — pure FileManager lookup,
    /// callable from the router's off-actor tool closures.
    nonisolated static var downloadsRoot: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// True when `url` sits inside Downloads or any granted root — i.e.
    /// the app can enumerate/read it without a fresh grant.
    func hasAccess(to url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        if Self.isDescendant(target, of: Self.downloadsRoot.standardizedFileURL.path) {
            return true
        }
        return grantedRoots.contains { root in
            Self.isDescendant(target, of: root.standardizedFileURL.path)
        }
    }

    /// The granted root (or Downloads) that contains `url`, if any.
    func accessRoot(for url: URL) -> URL? {
        let target = url.standardizedFileURL.path
        let downloads = Self.downloadsRoot
        if Self.isDescendant(target, of: downloads.standardizedFileURL.path) { return downloads }
        return grantedRoots.first { Self.isDescendant(target, of: $0.standardizedFileURL.path) }
    }

    /// Present a folder picker; on OK, persist an app-scoped bookmark,
    /// start its scope, and return the granted folder. Throws
    /// `CancelledError` if the user dismisses the panel.
    @discardableResult
    func grantAccess(startingAt directory: URL? = nil) throws -> URL {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a folder to give Verbinal access to its FITS files.")
        panel.prompt = String(localized: "Grant Access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            throw CancellationError()
        }
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        // Dedup by resolved path — re-granting a folder replaces its bookmark.
        bookmarks.removeAll { data in
            (try? Self.resolve(data))?.url.standardizedFileURL.path == url.standardizedFileURL.path
        }
        bookmarks.append(bookmark)
        persist()
        resolveAll()
        return url
    }

    /// Drop a granted folder (stops its scope on next launch; the held
    /// scope for this run is released too).
    func revoke(_ root: URL) {
        let path = root.standardizedFileURL.path
        bookmarks.removeAll { data in
            (try? Self.resolve(data))?.url.standardizedFileURL.path == path
        }
        persist()
        for granted in grantedRoots where granted.standardizedFileURL.path == path {
            granted.stopAccessingSecurityScopedResource()
        }
        grantedRoots.removeAll { $0.standardizedFileURL.path == path }
    }

    // MARK: - Private

    private func persist() {
        defaults.set(bookmarks, forKey: Self.defaultsKey)
    }

    /// Resolve every stored bookmark, start its scope, and refresh
    /// `grantedRoots`. Stale-but-resolvable bookmarks are re-minted;
    /// unresolvable ones are dropped.
    private func resolveAll() {
        var freshBookmarks: [Data] = []
        var roots: [URL] = []
        for data in bookmarks {
            guard let resolved = try? Self.resolve(data) else {
                Self.logger.notice("dropping unresolvable folder bookmark")
                continue
            }
            _ = resolved.url.startAccessingSecurityScopedResource()
            roots.append(resolved.url)
            if resolved.stale,
               let refreshed = try? resolved.url.bookmarkData(
                   options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                freshBookmarks.append(refreshed)
            } else {
                freshBookmarks.append(data)
            }
        }
        bookmarks = freshBookmarks
        grantedRoots = roots
        persist()
    }

    private static func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data, options: [.withSecurityScope],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
#endif
