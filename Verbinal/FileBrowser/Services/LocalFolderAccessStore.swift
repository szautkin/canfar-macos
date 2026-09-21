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
    ///
    /// In the App Sandbox this is often the *container* Downloads
    /// (`…/Containers/<bundle>/Data/Downloads`). Agents and `list_open_tabs`
    /// also emit the *user-facing* path (`/Users/<name>/Downloads`). Both
    /// must resolve as the same granted location.
    nonisolated static var downloadsRoot: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// The real user's Downloads (`/Users/<name>/Downloads`), even when
    /// the process is sandboxed and `FileManager` reports the container.
    nonisolated static var userFacingDownloadsRoot: URL {
        realUserHome().appendingPathComponent("Downloads", isDirectory: true)
    }

    /// POSIX home from the passwd database — not the container home.
    nonisolated static func realUserHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// True when `url` sits inside Downloads (container *or* user-facing)
    /// or any granted root — i.e. the app can enumerate/read it without
    /// a fresh grant.
    func hasAccess(to url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        for root in Self.downloadsRoots {
            if Self.isDescendant(target, of: root.standardizedFileURL.path) {
                return true
            }
        }
        return grantedRoots.contains { root in
            Self.isDescendant(target, of: root.standardizedFileURL.path)
        }
    }

    /// The granted root (or Downloads) that contains `url`, if any.
    func accessRoot(for url: URL) -> URL? {
        let target = url.standardizedFileURL.path
        for root in Self.downloadsRoots {
            if Self.isDescendant(target, of: root.standardizedFileURL.path) { return root }
        }
        return grantedRoots.first { Self.isDescendant(target, of: $0.standardizedFileURL.path) }
    }

    /// Map a user-facing Downloads path onto the container Downloads
    /// (the location the sandbox can actually read), and vice versa.
    /// Other paths pass through unchanged.
    nonisolated static func resolveSandboxPath(_ url: URL) -> URL {
        let target = url.standardizedFileURL.path
        let user = userFacingDownloadsRoot.standardizedFileURL.path
        let container = downloadsRoot.standardizedFileURL.path
        if user != container {
            if target == user || target.hasPrefix(user.hasSuffix("/") ? user : user + "/") {
                let rest = String(target.dropFirst(user.count))
                return URL(fileURLWithPath: container + rest, isDirectory: url.hasDirectoryPath)
            }
        }
        return url.standardizedFileURL
    }

    /// Path to show agents / the UI: prefer the user-facing Downloads
    /// form when the file actually lives under either Downloads root.
    nonisolated static func userFacingPath(for url: URL) -> String {
        let target = url.standardizedFileURL.path
        let user = userFacingDownloadsRoot.standardizedFileURL.path
        let container = downloadsRoot.standardizedFileURL.path
        if user != container, target == container || target.hasPrefix(container.hasSuffix("/") ? container : container + "/") {
            let rest = String(target.dropFirst(container.count))
            return user + rest
        }
        return target
    }

    /// Expand `~` against the **real** user home (`/Users/<name>`), not the
    /// sandbox container home. `NSString.expandingTildeInPath` in a
    /// sandboxed process maps `~/Downloads` onto the container, which is
    /// why `list_local_folder` returned `notReadable` on the same path
    /// `open_local_file` could open (2026-08-28 re-test).
    nonisolated static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return realUserHome().path }
        if trimmed.hasPrefix("~/") {
            return realUserHome().appendingPathComponent(String(trimmed.dropFirst(2))).path
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// Unique URLs that might be the same file/folder from opposite sides
    /// of the sandbox (user-facing Downloads ↔ container Downloads), plus
    /// Downloads-relative legacy `DownloadedObservation.localPath` values.
    nonisolated static func candidateURLs(for path: String, isDirectory: Bool) -> [URL] {
        let expanded = expandedPath(path)
        var urls: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if !urls.contains(where: { $0.path == standardized.path }) {
                urls.append(standardized)
            }
        }
        add(URL(fileURLWithPath: expanded, isDirectory: isDirectory))
        add(resolveSandboxPath(URL(fileURLWithPath: expanded, isDirectory: isDirectory)))
        add(URL(fileURLWithPath: userFacingPath(for: URL(fileURLWithPath: expanded, isDirectory: isDirectory)), isDirectory: isDirectory))
        if !expanded.hasPrefix("/") {
            for root in downloadsRoots {
                add(root.appendingPathComponent(expanded, isDirectory: isDirectory))
            }
        }
        return urls
    }

    /// First candidate that exists as a file (`directory: false`) or folder.
    nonisolated static func readableURL(for path: String, directory: Bool) -> URL? {
        for url in candidateURLs(for: path, isDirectory: directory) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue == directory {
                return url
            }
        }
        return nil
    }

    /// First candidate `contentsOfDirectory` can actually enumerate.
    /// Listing the container Downloads can fail while the user-facing
    /// path (or vice versa) succeeds.
    nonisolated static func listableDirectory(at path: String) -> URL? {
        for url in candidateURLs(for: path, isDirectory: true) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) != nil {
                return url
            }
        }
        return nil
    }

    nonisolated private static var downloadsRoots: [URL] {
        let a = downloadsRoot.standardizedFileURL
        let b = userFacingDownloadsRoot.standardizedFileURL
        if a.path == b.path { return [a] }
        return [a, b]
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
