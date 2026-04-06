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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.rootURL = docs
        self.currentURL = docs
    }

    func loadDirectory() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            nodes = contents.compactMap { url -> LocalFileNode? in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
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
        } catch {
            nodes = []
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
