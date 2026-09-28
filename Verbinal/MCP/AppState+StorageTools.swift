// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Storage (VOSpace) reads.
extension AppState {
    func makeListVOSpacePathTool(service: VOSpaceBrowserService) -> ListVOSpacePathTool {
        ListVOSpacePathTool(listNodes: { [weak self] path, limit in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            // `self.username` is a @MainActor property; direct
            // `await` does the actor hop without the redundant
            // `MainActor.run { self.username }` wrapper that
            // tripped the strict-concurrency check.
            let username = await self.username
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            let nodes = try await service.listNodes(username: username, path: path, limit: limit)
            return nodes.map(Self.flatten)
        })
    }

    func makeGetVOSpaceNodeTool(service: VOSpaceBrowserService) -> GetVOSpaceNodeTool {
        GetVOSpaceNodeTool(listNodes: { [weak self] path, limit in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            // `self.username` is a @MainActor property; direct
            // `await` does the actor hop without the redundant
            // `MainActor.run { self.username }` wrapper that
            // tripped the strict-concurrency check.
            let username = await self.username
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            let nodes = try await service.listNodes(username: username, path: path, limit: limit)
            return nodes.map(Self.flatten)
        })
    }

    func makeReadVOSpaceFileTool(service: VOSpaceBrowserService) -> ReadVOSpaceFileTool {
        ReadVOSpaceFileTool(fetch: { [weak self] path, offset, maxBytes in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let username = await self.username
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            let result = try await service.fetchBytes(
                username: username,
                path: path,
                offset: offset,
                maxBytes: maxBytes
            )
            return ReadVOSpaceFetchResult(data: result.data, totalBytes: result.totalBytes)
        })
    }

    private nonisolated static func flatten(_ node: VOSpaceNode) -> VOSpaceNodeOut {
        VOSpaceNodeOut(
            name: node.name,
            path: node.path,
            type: node.type.rawValue,
            sizeBytes: node.sizeBytes,
            contentType: node.mediaType,
            lastModified: node.lastModified,
            isPublic: node.isPublic
        )
    }
}
