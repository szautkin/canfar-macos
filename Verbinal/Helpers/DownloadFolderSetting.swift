// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
#if os(macOS)
import AppKit
#endif

/// The person's choice of download folder (plan 34 F): Settings ▸ General ▸
/// Downloads, and the line under an observation's files. Kept with an
/// app-scope bookmark, as granted folders are, and opened for the app's
/// run; `DownloadsFolder` reads it. The person's: an assistant cannot
/// change it.
@Observable
@MainActor
final class DownloadFolderSetting {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "DownloadFolder")
    private static let key = "verbinal.downloads.folderBookmark"

    /// Where downloads go now.
    private(set) var folder: URL = DownloadsFolder.system
    /// True while it is `~/Downloads`.
    private(set) var isDownloads = true
    /// The chosen folder's name when it cannot be opened now — a drive not
    /// mounted, a folder moved — and downloads go to `~/Downloads` instead.
    private(set) var unavailable: String?

    private let defaults: UserDefaults
    /// The chosen folder whose access is held, to give back on a change.
    private var opened: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        resolve()
    }

    /// The folder as the person reads it: `~/Downloads`, `~/Data/CFHT`.
    var displayPath: String {
        #if os(macOS)
        let home = LocalFolderAccessStore.realUserHome().path
        #else
        let home = NSHomeDirectory()
        #endif
        let path = folder.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Downloads go to `url` from now on.
    func choose(_ url: URL) {
        let isSystem = url.standardizedFileURL.resolvingSymlinksInPath() == DownloadsFolder.system.standardizedFileURL
        if isSystem {
            useDownloads()
            return
        }
        #if os(macOS)
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            Self.logger.error("download folder not kept: no bookmark")
            return
        }
        defaults.set(bookmark, forKey: Self.key)
        #endif
        resolve()
    }

    /// Back to `~/Downloads`.
    func useDownloads() {
        defaults.removeObject(forKey: Self.key)
        resolve()
    }

    #if os(macOS)
    /// Asks the person for a folder, starting at the current one.
    func chooseWithPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the Download Folder")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        guard UIPresentations.shared.runModal(panel, "Choose the Download Folder") == .OK, let url = panel.url else { return }
        choose(url)
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
    #endif

    /// Opens the kept choice — or none — and tells `DownloadsFolder`.
    private func resolve() {
        opened?.stopAccessingSecurityScopedResource()
        opened = nil
        unavailable = nil
        var chosen: URL?
        #if os(macOS)
        if let data = defaults.data(forKey: Self.key) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    opened = url
                    chosen = url
                    if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        defaults.set(fresh, forKey: Self.key)
                    }
                } else {
                    url.stopAccessingSecurityScopedResource()
                    unavailable = url.lastPathComponent
                }
            } else {
                unavailable = String(localized: "the chosen folder")
            }
        }
        #endif
        DownloadsFolder.chosen.withLock { $0 = chosen }
        folder = chosen ?? DownloadsFolder.system
        isDownloads = chosen == nil
    }
}
