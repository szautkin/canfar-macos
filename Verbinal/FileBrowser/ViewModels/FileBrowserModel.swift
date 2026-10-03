// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages the local file browser sidebar.
@Observable
@MainActor
final class FileBrowserModel {
    var rootURL: URL
    var currentURL: URL
    var nodes: [LocalFileNode] = []
    var filterText = ""
    var showOnlySupportedTypes = true
    /// Set when the directory itself couldn't be enumerated — lets the sidebar
    /// show a distinct "couldn't load" state instead of looking empty.
    var loadError: String?
    /// Count of entries in the last load whose metadata read failed and were
    /// omitted from `nodes`, so a partial read is flagged rather than silently
    /// dropping files.
    private(set) var loadSkippedCount = 0

    /// True when the current folder is outside the sandbox's reach and the
    /// user hasn't granted access — drives the "Grant Access…" prompt
    /// instead of a bare permission error (2026-07-21 Mac QA, F14).
    private(set) var needsGrant = false

    /// User-granted folder access, injected from `AppState`. `nil` in
    /// previews/tests falls back to Downloads-only reach.
    var access: LocalFolderAccessStore?

    var filteredNodes: [LocalFileNode] {
        var filtered = nodes
        if showOnlySupportedTypes {
            filtered = filtered.filter { $0.isDirectory || LocalFileNode.supportedExtensions.contains($0.fileExtension) }
        }
        if !filterText.isEmpty {
            let query = filterText.lowercased()
            filtered = filtered.filter { $0.name.lowercased().contains(query) }
        }
        return filtered
    }

    init() {
        // Start in Downloads — the one user folder the sandbox grants by
        // default, so the browser opens to something readable instead of
        // ~/Documents (which is denied until the user grants it). The
        // person's own, as `list_local_folder` lists it: in the sandbox,
        // FileManager's is the container's link to it (plan 30 F).
        let start = LocalFolderAccessStore.userFacingDownloadsRoot
        self.rootURL = start
        self.currentURL = start
    }

    /// Grant access to the current folder (or a folder the user picks)
    /// via the sandbox powerbox, then reload. No-op without an access
    /// store.
    func grantAccessToCurrentFolder() async {
        guard let access else { return }
        if let granted = try? await access.grantAccess(startingAt: currentURL) {
            currentURL = granted
            loadDirectory()
        }
    }

    func loadDirectory() {
        loadError = nil
        loadSkippedCount = 0
        needsGrant = false
        // Cheap pre-check: if the folder is outside the sandbox's reach and
        // hasn't been granted, surface the grant prompt rather than letting
        // the enumeration fail with a raw permission error.
        if let access, !access.hasAccess(to: currentURL) {
            nodes = []
            needsGrant = true
            return
        }
        do {
            // The folder a link points to: listing the link itself fails, as
            // "The file "Downloads" couldn't be opened" (plan 30 F).
            let contents = try FileManager.default.contentsOfDirectory(
                at: currentURL.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            var skipped = 0
            nodes = contents.compactMap { url -> LocalFileNode? in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
                    skipped += 1   // count, don't silently vanish
                    return nil
                }
                return LocalFileNode(
                    id: url.path,
                    name: url.lastPathComponent,
                    url: url,
                    isDirectory: values.isDirectory ?? false,
                    fileSize: values.fileSize.map(Int64.init),
                    modifiedDate: values.contentModificationDate
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            loadSkippedCount = skipped
        } catch {
            nodes = []
            loadError = error.localizedDescription
        }
    }

    func navigateInto(_ node: LocalFileNode) {
        guard node.isDirectory else { return }
        currentURL = node.url
        loadDirectory()
    }

    func goUp() {
        guard currentURL != rootURL else { return }
        currentURL = currentURL.deletingLastPathComponent()
        loadDirectory()
    }

    var canGoUp: Bool { currentURL != rootURL }

    var breadcrumbName: String {
        currentURL.lastPathComponent
    }
}
