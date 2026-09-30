// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// The sessions a write names: ids or their starts, `all`, or this session.
private func sessions(_ raw: [String]?, context: AIToolContext, query: SessionLogQuery) async throws -> [UUID] {
    guard let raw, !raw.isEmpty else {
        guard let own = context.session else {
            throw ToolFailureReason.invalidArgument("name the sessions — list_session_logs lists them")
        }
        return [own]
    }
    if raw.contains(where: { $0.lowercased() == "all" }) {
        return query.store.list().map(\.header.session)
    }
    var found: [UUID] = []
    for name in raw {
        guard let id = await query.session(named: name) else {
            throw ToolFailureReason.unknownTarget("no session log \(name) — list_session_logs lists them")
        }
        found.append(id)
    }
    return found
}

// MARK: - export_session_log

/// `export_session_log` — session logs written to Downloads, as text or
/// JSON Lines (plan 23 L4).
struct ExportSessionLogTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        var sessions: [String]?
        var format: String?
    }

    struct Payload: Codable, Sendable {
        let sessions: [UUID]
        let format: SessionLogExport.Format
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "export_session_log",
        description: "Write session logs to a file in the person's Downloads folder — for them to read or attach to a report, or for a tool: `text` (default) is the lines as the Session Logs view shows them, each session headed by its header (versions, endpoints, Auto-apply, sign-in), a call's requests under it and a failure's codes after it; `jsonl` is the entries as stored. Several sessions go into one file. The answer names the file.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "sessions": { "type": "array", "items": { "type": "string" }, "description": "Session ids or their first 8 characters, or [\"all\"]. Default: this session." },
            "format": { "type": "string", "enum": ["text", "jsonl"], "description": "text (default) or jsonl." }
          },
          "additionalProperties": false
        }
        """#
    )

    let query: SessionLogQuery

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let ids = try await sessions(args.sessions, context: context, query: query)
        guard !ids.isEmpty else { throw ToolFailureReason.invalidArgument("there is no session log to export") }
        let format = SessionLogExport.Format(rawValue: args.format ?? "text") ?? .text
        return try .encoding(kind: "export_session_log",
                             summary: "Export \(ids.count) session \(ids.count == 1 ? "log" : "logs") as \(format == .text ? "text" : "JSON Lines") to Downloads",
                             payload: Payload(sessions: ids, format: format))
    }
}

struct ExportSessionLogApplier: ResultReportingApplier {
    let kind = "export_session_log"
    let query: SessionLogQuery
    let activity: AgentActivityStore
    /// Where the file goes: Downloads.
    var folder: @Sendable () -> URL = { DownloadsFolder.url }

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(ExportSessionLogTool.Payload.self, from: proposal.payload)
        var logs: [SessionLogExport.Log] = []
        for id in payload.sessions {
            guard let log = await query.log(of: id) else { throw ProposalApplyError.backendError("no session log \(id.uuidString)") }
            logs.append((log.header, log.entries))
        }
        let url = folder().appendingPathComponent(
            "\(SessionLogExport.name(for: logs.count)).\(payload.format.fileExtension)")
        do {
            try SessionLogExport.write(logs, as: payload.format, to: url)
        } catch {
            throw ProposalApplyError.backendError("could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        return (try? JSONEncoder().encode(AutoAppliedAck.Extra(file: url.path))) ?? Data()
    }
}

// MARK: - delete_session_logs

/// `delete_session_logs` — destructive: it waits in Pending for the person,
/// and never deletes an open session's log (plan 23 L4).
struct DeleteSessionLogsTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        var sessions: [String]?
        var allClosed: Bool?
    }

    struct Payload: Codable, Sendable {
        let sessions: [UUID]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_session_logs",
        description: "Delete session logs kept on this Mac: the ones named, or every closed one (`allClosed`). An open session's log — yours, or another assistant's still connected — is never deleted. Destructive: it waits in Pending for the person to approve. Logs also go on their own after 10 days, or when all of them pass 10 MB (list_session_logs states the rule).",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "sessions": { "type": "array", "items": { "type": "string" }, "description": "Session ids or their first 8 characters." },
            "allClosed": { "type": "boolean", "description": "Every closed session's log." }
          },
          "additionalProperties": false
        }
        """#
    )

    let query: SessionLogQuery

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let open = await query.hub.openSessions
        let named: [UUID]
        if args.allClosed == true {
            named = query.store.list().map(\.header.session)
        } else {
            guard let raw = args.sessions, !raw.isEmpty else {
                throw ToolFailureReason.invalidArgument("name the sessions, or pass allClosed — list_session_logs lists them")
            }
            named = try await sessions(raw, context: context, query: query)
        }
        let closed = named.filter { !open.contains($0) }
        guard !closed.isEmpty else {
            throw ToolFailureReason.invalidArgument("an open session's log is never deleted; none of those named is closed")
        }
        let logs = query.store.list().filter { closed.contains($0.header.session) }
        let names = logs.prefix(3).map { "\($0.header.client), \($0.header.session.uuidString.prefix(8))" }.joined(separator: "; ")
        return try .encoding(kind: "delete_session_logs",
                             summary: "Delete \(closed.count) session \(closed.count == 1 ? "log" : "logs") (\(names)\(logs.count > 3 ? "; …" : ""))",
                             payload: Payload(sessions: closed))
    }
}

struct DeleteSessionLogsApplier: ResultReportingApplier {
    let kind = "delete_session_logs"
    let query: SessionLogQuery
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(DeleteSessionLogsTool.Payload.self, from: proposal.payload)
        let open = await query.hub.openSessions
        let deleted = query.store.delete(Set(payload.sessions), open: open)
        let kept = payload.sessions.count - deleted.count
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        let note = kept == 0 ? nil : "\(kept) not deleted: open again, gone already, or not deletable"
        return (try? JSONEncoder().encode(AutoAppliedAck.Extra(succeeded: deleted.map(\.uuidString), note: note))) ?? Data()
    }
}
