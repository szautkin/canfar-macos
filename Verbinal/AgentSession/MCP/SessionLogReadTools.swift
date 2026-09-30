// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// A session as a reader sees it: its header, how long, how it ended.
struct SessionLogInfo: Encodable, Sendable {
    let session: String
    let client: String
    let opened: Date
    let seconds: Double
    /// disconnected, verbinalQuit — nil while open.
    let ending: String?
    let open: Bool
    /// The session this call belongs to.
    let isThisSession: Bool
    let header: SessionLogHeader
}

// MARK: - get_session_log

/// `get_session_log` — what is happening, and what happened, in a session:
/// its entries in words, filtered, summarised; `now` for an open one
/// (plan 23 L3).
struct GetSessionLogTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        var session: String?
        var since: Int?
        var only: String?
        var who: String?
        var about: String?
        var text: String?
        var from: String?
        var to: String?
        var limit: Int?
    }

    struct Output: Encodable, Sendable {
        let session: SessionLogInfo
        /// What is happening right now; only for an open session.
        let now: SessionNow?
        let summary: SessionLogQuery.Summary
        /// Newest last.
        let entries: [SessionLogEntry]
        /// Pass as `since` to read only what is newer.
        let nextToken: Int
        /// Some entries after `since` were dropped to keep the log small.
        let expired: Bool
        /// More matched than `limit`; the oldest were left out.
        let truncated: Bool
    }

    static let kinds = ["actions", "failures", "decisions", "calls", "tasks", "proposals", "requests", "app"]

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_session_log",
        description: "The session log: everything that happened in Verbinal while you have been connected — your calls (with the CADC and CANFAR requests each made, how long each took and what its outcome means), every change anyone made (created, launched, downloaded, deleted …, with who and why), the app's decisions with their rules (applied at once or held, retried or not, a deadline reached), tasks, failed requests, services failing and recovering, sign-in — and `now`: requests still waiting, tasks running and what they wait on, proposals waiting and why, services failing. Each entry has one sentence (`line`), who, why, outcome, seconds, ids and codes. Read it when something is slow or failed, or to find what happened; `explain_log_entry` follows one entry's cause and effect. Poll with `since` = the last `nextToken`. `session` reads another (see `list_session_logs`), such as yours from before Verbinal restarted. Read-only.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "session": { "type": "string", "description": "A session's id, or its first 8 characters. Default: this session." },
            "since": { "type": "integer", "minimum": 0, "description": "Only entries after this token (a previous nextToken)." },
            "only": { "type": "string", "enum": ["actions", "failures", "decisions", "calls", "tasks", "proposals", "requests", "app"], "description": "One kind of entry." },
            "who": { "type": "string", "enum": ["assistant", "anotherAssistant", "person", "app"], "description": "assistant = you (this session's); anotherAssistant; person; app = Verbinal itself." },
            "about": { "type": "string", "description": "Everything about one thing: a proposal, call or session id (or its start), a task number, a tool, a service id (cadc-tap, skaha, vospace …), or a file's name." },
            "text": { "type": "string", "description": "Words in the entries' sentences." },
            "from": { "type": "string", "description": "ISO 8601 time: entries at or after it." },
            "to": { "type": "string", "description": "ISO 8601 time: entries at or before it." },
            "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "How many, newest kept (default 50)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let query: SessionLogQuery
    let now: @Sendable () async -> SessionNow

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let session = try await resolveSession(args.session, context: context, query: query)
        guard let log = await query.log(of: session) else {
            throw ToolFailureReason.unknownTarget("no session log \(session.uuidString)")
        }
        let iso = ISO8601DateFormatter()
        let filter = SessionLogQuery.Filter(
            only: args.only, who: args.who, about: args.about, text: args.text,
            from: args.from.flatMap(iso.date(from:)), to: args.to.flatMap(iso.date(from:)))
        let since = args.since ?? 0
        let after = log.entries.filter { $0.token > since }
        let expired = since > 0 && after.first.map { $0.token > since + 1 } == true
        let matched = SessionLogQuery.filter(SessionLogQuery.folded(after), filter)
        let limit = min(max(args.limit ?? 50, 1), 500)
        return Output(
            session: info(log, isThis: session == context.session),
            now: log.open ? await now() : nil,
            summary: SessionLogQuery.summary(log.entries),
            entries: Array(matched.suffix(limit)),
            nextToken: log.entries.last?.token ?? since,
            expired: expired,
            truncated: matched.count > limit)
    }
}

// MARK: - explain_log_entry

/// `explain_log_entry` — one entry, and its chain of cause and effect.
struct ExplainLogEntryTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let token: Int
        var session: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "explain_log_entry",
        description: "Why one thing happened, and what came of it: the session-log entry `token`, whole (all its ids and codes), with its causes (the call that set it going or proposed it, the decision about its proposal and the rule, the task it ran in) and its effects (the decisions, tasks, requests and changes it led to), and `story` — the chain in plain sentences with times, e.g. \"14:01:12 Called delete_session — proposed … → 14:01:12 Verbinal decided: … waits in Pending: a delete always waits for the person → 14:02:40 Deleted session … — applied by the person … Done in 1.8 s.\" A reply's timing note and a failure carry the token to explain. Read-only.",
        schema: #"""
        {
          "type": "object",
          "required": ["token"],
          "properties": {
            "token": { "type": "integer", "minimum": 1, "description": "The entry's token, from get_session_log or a reply's timing note." },
            "session": { "type": "string", "description": "A session's id, or its first 8 characters. Default: this session." }
          },
          "additionalProperties": false
        }
        """#
    )

    let query: SessionLogQuery

    func handle(_ args: Args, context: AIToolContext) async throws -> SessionLogQuery.Explanation {
        let session = try await resolveSession(args.session, context: context, query: query)
        guard let log = await query.log(of: session),
              let explanation = SessionLogQuery.explain(args.token, in: log.entries) else {
            throw ToolFailureReason.unknownTarget("no entry \(args.token) in session \(session.uuidString.prefix(8)) — get_session_log lists its tokens")
        }
        return explanation
    }
}

// MARK: - list_session_logs

/// `list_session_logs` — every session log kept on this Mac.
struct ListSessionLogsTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        struct Item: Encodable, Sendable {
            let session: String
            let client: String
            let opened: Date
            let lastAt: Date
            let ending: String?
            let open: Bool
            let isThisSession: Bool
            let entries: Int
            let actions: Int
            let failures: Int
            let bytes: Int
        }
        /// Newest first.
        let sessions: [Item]
        let totalBytes: Int
        /// How long logs are kept.
        let retention: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_session_logs",
        description: "Every assistant session log kept on this Mac, newest first: its id, the assistant's client, when it opened and last saw anything, how it ended (disconnected, or verbinalQuit — Verbinal quit or restarted while it was open), its entries, changes and failures, and whether it is this session. After Verbinal restarts you are in a new session: find the one before here and read it with get_session_log's `session`. States the retention rule. Read-only.",
        schema: #"""
        { "type": "object", "properties": {}, "additionalProperties": false }
        """#
    )

    let query: SessionLogQuery

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        let open = await query.hub.openSessions
        let logs = query.store.list()
        return Output(
            sessions: logs.map { log in
                .init(session: log.header.session.uuidString, client: log.header.client, opened: log.header.opened,
                      lastAt: log.lastAt, ending: log.ending, open: open.contains(log.header.session),
                      isThisSession: log.header.session == context.session, entries: log.entries,
                      actions: log.actions, failures: log.failures, bytes: log.bytes)
            },
            totalBytes: logs.map(\.bytes).reduce(0, +),
            retention: SessionLogRetention.rule)
    }
}

// MARK: - Shared

/// The session a call means: the one named, else its own, else the newest.
func resolveSession(_ raw: String?, context: AIToolContext, query: SessionLogQuery) async throws -> UUID {
    if let raw, !raw.isEmpty {
        guard let named = await query.session(named: raw) else {
            throw ToolFailureReason.unknownTarget("no session log \(raw) — list_session_logs lists them")
        }
        return named
    }
    if let own = context.session { return own }
    guard let newest = query.store.list().first?.header.session else {
        throw ToolFailureReason.unknownTarget("no session log yet — logs are kept for assistants connected over MCP")
    }
    return newest
}

func info(_ log: (header: SessionLogHeader, entries: [SessionLogEntry], open: Bool), isThis: Bool) -> SessionLogInfo {
    let last = log.entries.last?.at ?? log.header.opened
    return SessionLogInfo(session: log.header.session.uuidString, client: log.header.client, opened: log.header.opened,
                          seconds: last.timeIntervalSince(log.header.opened),
                          ending: log.entries.last(where: { $0.kind == .closed })?.outcome,
                          open: log.open, isThisSession: isThis, header: log.header)
}
