// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

extension AppState {
    /// What an assistant made, and the kinds that depend on what a change
    /// acts on (plan 30 A6): a removal of only what an assistant made, an
    /// upload over a file.
    func wireAssistantMade() {
        let made = AssistantMadeStore()
        let files = VOSpaceBrowserService(network: network, endpoints: endpoints)
        agentsService.kindResolver = { [weak self] proposal in
            let username = self?.username ?? ""
            return await ChangeKindResolver(
                username: username,
                isMade: { key in await MainActor.run { made.contains(key) } },
                subtree: { path in await Self.subtree(of: path, files: files, username: username) },
                exists: { path in await Self.node(at: path, files: files, username: username).map { $0 != nil } }
            ).kind(of: proposal)
        }
        agentsService.onApplied = { [weak self] proposal, result in
            made.applied(proposal, result: result, username: self?.username ?? "")
        }
    }

    /// The node at a VOSpace path, from its folder's listing: `.some(nil)`
    /// when nothing is there, nil when VOSpace cannot say.
    nonisolated static func node(at path: String, files: VOSpaceBrowserService, username: String) async -> VOSpaceNode?? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let nodes = try? await files.listNodes(username: username, path: parent) else { return nil }
        return .some(nodes.first { $0.name == name })
    }

    /// Every path under a VOSpace folder — none under a file — at most 500;
    /// nil when VOSpace cannot say, or there are more.
    nonisolated static func subtree(of path: String, files: VOSpaceBrowserService, username: String) async -> [String]? {
        guard let found = await node(at: path, files: files, username: username) else { return nil }
        guard let node = found, node.type == .container else { return [] }
        var paths: [String] = []
        var folders = [path]
        while let folder = folders.popLast() {
            guard let nodes = try? await files.listNodes(username: username, path: folder) else { return nil }
            for child in nodes {
                paths.append(child.path)
                if child.type == .container { folders.append(child.path) }
                if paths.count > 500 { return nil }
            }
        }
        return paths
    }
}
