// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Polling event-stream tool. Agents pass back the highest token they've
/// seen in `since_token`; the response carries new entries plus a
/// `nextToken` to use on the following poll.
///
/// Pattern adopted from VT ADR-0037: same shape, polling now, MCP
/// resource subscription possible later without changing the wire.
struct ListEventsTool: AITool {
    static let verbClass: VerbClass = .proposalLifecycle
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        /// String to dodge JSON number-precision concerns. Agents may
        /// send "" or omit to read from the start of the buffer.
        var since_token: String?
    }

    struct Output: Encodable, Sendable {
        let events: [Item]
        let nextToken: String
        let expired: Bool
        struct Item: Encodable, Sendable {
            let token: String
            let occurredAtISO: String
            let kind: String          // "proposalArrived" | "proposalApplied" | "proposalRejected" | "proposalWithdrawn"
            let proposalID: String
            let proposalKind: String
            let originKind: String?   // only set for proposalArrived
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_events",
        description: "Poll the agent event log. Pass `since_token` to read only events newer than that token. Response includes nextToken to use on the following poll. If `expired` is true, your token is older than the buffer; re-baseline with an empty since_token.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "since_token": { "type": "string", "description": "Token from a previous response. Empty/absent reads from the start of the retained buffer." }
          },
          "additionalProperties": false
        }
        """#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        guard let log = context.eventLog else {
            // No event log wired — return an empty result rather than
            // failing, so a partially-configured deployment still works.
            do {
                let bytes = try JSONEncoder().encode(Output(events: [], nextToken: "0", expired: false))
                return .data(bytes)
            } catch {
                return .failed(.backendError("\(error)"))
            }
        }
        let since = UInt64(args.since_token ?? "0") ?? 0
        let result = await log.entries(since: since)
        let next = await log.currentToken()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let items = result.entries.map { entry in
            Self.flatten(entry, iso: iso)
        }
        do {
            let bytes = try JSONEncoder().encode(Output(
                events: items,
                nextToken: String(next),
                expired: result.expired
            ))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }

    private static func flatten(_ entry: AgentEventEntry,
                                iso: ISO8601DateFormatter) -> Output.Item {
        switch entry.event {
        case .proposalArrived(let id, let kind, let originKind):
            return Output.Item(
                token: String(entry.token),
                occurredAtISO: iso.string(from: entry.occurredAt),
                kind: "proposalArrived",
                proposalID: id.uuidString,
                proposalKind: kind,
                originKind: originKind
            )
        case .proposalApplied(let id, let kind):
            return Output.Item(
                token: String(entry.token),
                occurredAtISO: iso.string(from: entry.occurredAt),
                kind: "proposalApplied",
                proposalID: id.uuidString,
                proposalKind: kind,
                originKind: nil
            )
        case .proposalRejected(let id, let kind):
            return Output.Item(
                token: String(entry.token),
                occurredAtISO: iso.string(from: entry.occurredAt),
                kind: "proposalRejected",
                proposalID: id.uuidString,
                proposalKind: kind,
                originKind: nil
            )
        case .proposalWithdrawn(let id, let kind):
            return Output.Item(
                token: String(entry.token),
                occurredAtISO: iso.string(from: entry.occurredAt),
                kind: "proposalWithdrawn",
                proposalID: id.uuidString,
                proposalKind: kind,
                originKind: nil
            )
        }
    }
}
