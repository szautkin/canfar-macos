// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Session parity tools — the Portal interactions the read/write batch
/// didn't cover: the per-session Events sheet, the session log view,
/// and the Connect button. Capability closures are injected at wiring
/// time.

// MARK: - Kubernetes events

/// The platform's events text as the tools give it: the platform writes
/// `<none>` when there are none (QA L15), which is no event.
enum KubernetesEvents {
    static func text(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "<none>" ? "" : trimmed
    }
}

// MARK: - get_session_events

/// Kubernetes-level events for an interactive session — the session
/// card's Events sheet (the interactive twin of
/// `get_headless_job_events`).
struct GetSessionEventsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Output: Encodable, Sendable {
        let id: String
        /// The events as the platform lists them; empty when there are none.
        let events: String
        let hasEvents: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_session_events",
        description: "Kubernetes-level scheduling/lifecycle events for one interactive session (by id from `list_sessions`) — the session card's Events sheet. `events` is the platform's list as text, empty (and `hasEvents` false) when there are none. Use to diagnose why a session is Pending or failed to schedule; use `get_session_logs` for the container's own output.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable (String) async throws -> String

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let events = KubernetesEvents.text(try await fetch(args.id))
        return Output(id: args.id, events: events, hasEvents: !events.isEmpty)
    }
}

// MARK: - get_session_logs

/// Container stdout/stderr for an interactive session — the session
/// card's log view.
struct GetSessionLogsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
        /// Return only the last N bytes (default 65536, max 1 MiB).
        var tailBytes: Int?
    }

    struct Output: Encodable, Sendable {
        let id: String
        let logs: String
        let truncated: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_session_logs",
        description: "Container stdout/stderr for one interactive session (by id from `list_sessions`) — the session card's log view. Returns the tail (default 64 KiB, `tailBytes` up to 1 MiB); `truncated: true` means earlier output was cut. The headless twin is `get_headless_job_logs`.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": {
            "id":        { "type": "string" },
            "tailBytes": { "type": "integer", "minimum": 1024, "maximum": 1048576, "description": "Tail size in bytes (default 65536)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable (String) async throws -> String

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let logs = try await fetch(args.id)
        let cap = min(max(args.tailBytes ?? 65536, 1024), 1_048_576)
        if logs.utf8.count > cap {
            let tail = String(decoding: Array(logs.utf8.suffix(cap)), as: UTF8.self)
            return Output(id: args.id, logs: tail, truncated: true)
        }
        return Output(id: args.id, logs: logs, truncated: false)
    }
}

// MARK: - open_session

/// Open a running session's connect URL in the user's browser — the
/// session card's Connect button. Live-applied.
struct OpenSessionTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let connectURL: String
    }

    enum Result_: Sendable {
        case opened(String)
        case rejected(String)
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "open_session",
        description: "Open a running interactive session's connect URL in the user's default browser — the session card's Connect button. The session must be in Running state (`list_sessions`). Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let open: @Sendable (String) async -> Result_

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        switch await open(args.id) {
        case .rejected(let message):
            return .failed(.invalidArgument(message))
        case .opened(let url):
            do {
                let bytes = try JSONEncoder().encode(Output(applied: true, connectURL: url))
                return .data(bytes)
            } catch {
                return .failed(.backendError("\(error)"))
            }
        }
    }
}
