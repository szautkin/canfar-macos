// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - list_sessions

struct ListSessionsTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let sessions: [Item]
        struct Item: Encodable, Sendable {
            let id: String
            let name: String
            let type: String
            let status: String
            let image: String
            let connectURL: String
            let startedTime: String
            let expiresTime: String
            let memoryAllocated: String
            let memoryUsage: String
            let cpuAllocated: String
            let cpuUsage: String
            let gpuAllocated: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_sessions",
        description: "List the user's currently running interactive Skaha sessions (notebook/desktop/firefly/carta/contributed). Headless and desktop-app sessions are excluded.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let fetchAll: @Sendable () async throws -> [SessionOut]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        do {
            let raw = try await fetchAll()
            return Output(sessions: raw.map(Self.flatten))
        } catch {
            let msg = "\(error)"
            if msg.lowercased().contains("auth") { throw ToolFailureReason.authRequired }
            throw ToolFailureReason.backendError(msg)
        }
    }

    private static func flatten(_ s: SessionOut) -> Output.Item {
        Output.Item(
            id: s.id, name: s.name, type: s.type,
            status: s.status, image: s.image,
            connectURL: s.connectURL,
            startedTime: s.startedTime,
            expiresTime: s.expiresTime,
            memoryAllocated: s.memoryAllocated,
            memoryUsage: s.memoryUsage,
            cpuAllocated: s.cpuAllocated,
            cpuUsage: s.cpuUsage,
            gpuAllocated: s.gpuAllocated
        )
    }
}

// MARK: - get_session

struct GetSessionTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    typealias Output = ListSessionsTool.Output.Item

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_session",
        description: "Look up one session by id. Returns the same shape as list_sessions[i].",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let fetchAll: @Sendable () async throws -> [SessionOut]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let all = try await fetchAll()
        guard let match = all.first(where: { $0.id == args.id }) else {
            throw ToolFailureReason.unknownTarget("session \(args.id)")
        }
        return Output(
            id: match.id, name: match.name, type: match.type,
            status: match.status, image: match.image,
            connectURL: match.connectURL,
            startedTime: match.startedTime,
            expiresTime: match.expiresTime,
            memoryAllocated: match.memoryAllocated,
            memoryUsage: match.memoryUsage,
            cpuAllocated: match.cpuAllocated,
            cpuUsage: match.cpuUsage,
            gpuAllocated: match.gpuAllocated
        )
    }
}

// MARK: - list_session_types

struct ListSessionTypesTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let types: [String]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_session_types",
        description: "Static list of supported interactive session types: notebook, desktop, firefly, carta, contributed.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        Output(types: ["notebook", "desktop", "firefly", "carta", "contributed"])
    }
}

// MARK: - list_recent_launches

struct ListRecentLaunchesTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let entries: [Entry]
        struct Entry: Encodable, Sendable {
            let id: String
            let name: String
            let type: String
            let image: String
            let project: String
            let resourceType: String
            /// Omitted when `resourceType == "flexible"` — those launches
            /// don't pin specific values, and the persisted `0/0/0`
            /// sentinels were misleading agents into reading them as
            /// "user wanted zero cores".
            let cores: Int?
            let ram: Int?
            let gpus: Int?
            let launchedAtISO: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_recent_launches",
        description: "Recent session launches (most-recent first). Useful for re-launching a session with the same params.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> [RecentLaunchOut]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let entries = await snapshot().map { launch -> Output.Entry in
            let isFixed = launch.resourceType == "fixed"
            return Output.Entry(
                id: launch.id, name: launch.name, type: launch.type,
                image: launch.image, project: launch.project,
                resourceType: launch.resourceType,
                cores: isFixed ? launch.cores : nil,
                ram:   isFixed ? launch.ram   : nil,
                gpus:  isFixed ? launch.gpus  : nil,
                launchedAtISO: iso.string(from: launch.launchedAt)
            )
        }
        return Output(entries: entries)
    }
}

// MARK: - DTOs

struct SessionOut: Sendable {
    let id: String
    let name: String
    let type: String
    let status: String
    let image: String
    let connectURL: String
    let startedTime: String
    let expiresTime: String
    let memoryAllocated: String
    let memoryUsage: String
    let cpuAllocated: String
    let cpuUsage: String
    let gpuAllocated: String
}

struct RecentLaunchOut: Sendable {
    let id: String
    let name: String
    let type: String
    let image: String
    let project: String
    let resourceType: String
    let cores: Int
    let ram: Int
    let gpus: Int
    let launchedAt: Date
}
