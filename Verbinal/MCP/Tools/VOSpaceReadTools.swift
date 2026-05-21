// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - list_vospace_path

/// List the contents of a VOSpace path. Returns a flat array of node
/// records (file or container). Paths are slash-separated, root is "".
struct ListVOSpacePathTool: JSONReadTool {
    // VOSpace listing is a fast XML directory walk; 30s is well
    // above the median response time and catches the transport-
    // stall failure mode the 2026-05-15 QA report flagged for
    // other list_* tools.
    var toolTimeoutSeconds: TimeInterval { 30 }
    struct Args: Decodable, Sendable {
        var path: String?
        var limit: Int?
    }

    struct Output: Encodable, Sendable {
        let path: String
        let nodes: [Node]
        struct Node: Encodable, Sendable {
            let name: String
            let path: String
            let type: String              // "container" | "dataNode" | "linkNode"
            let sizeBytes: Int64?
            let contentType: String?
            let lastModifiedISO: String?
            let isPublic: Bool
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_vospace_path",
        description: "List contents of a VOSpace path (root is empty string). Optional `limit` (default 200, max 500). The VOSpace REST endpoint doesn't always honour `?limit=` server-side, so the tool truncates client-side too — the response is always ≤ the requested limit. Requires auth.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "path":  { "type": "string" },
            "limit": { "type": "integer", "minimum": 1, "maximum": 500 }
          },
          "additionalProperties": false
        }
        """#
    )

    let listNodes: @Sendable (_ path: String, _ limit: Int) async throws -> [VOSpaceNodeOut]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let path = args.path ?? ""
        let limit = min(args.limit ?? 200, 500)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        do {
            let nodes = try await listNodes(path, limit)
            // The VOSpace REST endpoint accepts `?limit=` but doesn't
            // always honour it (observed: ~1100 rows returned for
            // limit=200). Truncate client-side so the tool's contract
            // matches its schema regardless of server behaviour.
            let capped = Array(nodes.prefix(limit))
            return Output(
                path: path,
                nodes: capped.map {
                    Output.Node(
                        name: $0.name,
                        path: $0.path,
                        type: $0.type,
                        sizeBytes: $0.sizeBytes,
                        contentType: $0.contentType,
                        lastModifiedISO: $0.lastModified.map { iso.string(from: $0) },
                        isPublic: $0.isPublic
                    )
                }
            )
        } catch {
            let message = "\(error)"
            if message.lowercased().contains("auth") {
                throw ToolFailureReason.authRequired
            }
            throw ToolFailureReason.backendError(message)
        }
    }
}

// MARK: - get_vospace_node

/// Fetch one node's metadata. Implemented as a list-of-parent + filter so
/// we don't add a service method just for one tool.
struct GetVOSpaceNodeTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let path: String
    }

    typealias Output = ListVOSpacePathTool.Output.Node

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_vospace_node",
        description: "Fetch metadata for one VOSpace node by absolute path.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": { "path": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let listNodes: @Sendable (_ path: String, _ limit: Int) async throws -> [VOSpaceNodeOut]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let trimmed = args.path.trimmingCharacters(in: .init(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw ToolFailureReason.invalidArgument("path cannot be root for get_vospace_node")
        }
        let lastSlash = trimmed.lastIndex(of: "/")
        let parent = lastSlash.map { String(trimmed[trimmed.startIndex..<$0]) } ?? ""
        let leaf = lastSlash.map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        do {
            let nodes = try await listNodes(parent, 500)
            guard let match = nodes.first(where: { $0.name == leaf }) else {
                throw ToolFailureReason.unknownTarget("vospace_node \(args.path)")
            }
            return Output(
                name: match.name,
                path: match.path,
                type: match.type,
                sizeBytes: match.sizeBytes,
                contentType: match.contentType,
                lastModifiedISO: match.lastModified.map { iso.string(from: $0) },
                isPublic: match.isPublic
            )
        } catch let f as ToolFailureReason {
            throw f
        } catch {
            throw ToolFailureReason.backendError("\(error)")
        }
    }
}

// MARK: - DTO

struct VOSpaceNodeOut: Sendable {
    let name: String
    let path: String
    let type: String
    let sizeBytes: Int64?
    let contentType: String?
    let lastModified: Date?
    let isPublic: Bool
}
