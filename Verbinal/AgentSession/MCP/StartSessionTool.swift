// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `start_session` — the assistant's handshake (plan 25 S). It says who it
/// is; Verbinal asks the person, who allows the session with instructions
/// for it, or declines. Allowed, it answers the session's id — the id every
/// entry of the session's log carries — and the person's instructions.
/// Until then, no other tool but `describe_app` works (M).
struct StartSessionTool: AITool {
    static let verbClass: VerbClass = .sessionControl
    static let agentSafe = true

    struct Args: Decodable, Sendable {
        let agent: String
        var model: String?
        var purpose: String?
    }

    struct Output: Encodable, Sendable {
        /// Every entry of this session's log carries it.
        let session: String
        /// The person's instructions for this session, word for word: follow them.
        let instructions: String
        let allowedAt: Date
        let log: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "start_session",
        description: "Start your session with Verbinal — call this first: no other tool but describe_app works before it. Say who you are (`agent`, and `model` if you know it) and, in one sentence, your `purpose`. Verbinal asks the person, who allows the session — often with instructions for it — or declines; the call waits for their answer. Allowed, it answers `session`, the id every entry of your session's log carries (get_session_log reads them), and `instructions`: the person's instructions for this session, which you must follow throughout. Calling it again answers the same session without asking again. Declined, it fails with sessionDeclined: ask the person in the conversation before trying again.",
        schema: #"""
        {
          "type": "object",
          "required": ["agent"],
          "properties": {
            "agent": { "type": "string", "minLength": 1, "maxLength": 80, "description": "Your name, as the person should see it, e.g. \"Claude\"." },
            "model": { "type": "string", "maxLength": 80, "description": "Your model, if you know it." },
            "purpose": { "type": "string", "maxLength": 300, "description": "What you are here to do, in one sentence." }
          },
          "additionalProperties": false
        }
        """#
    )

    let approvals: SessionApprovals
    /// Writes an entry to the session's log.
    let note: @Sendable (_ session: UUID, _ entry: SessionLogEntry) async -> Void

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        guard let session = context.session else {
            return .failed(.invalidArgument("start_session is for an assistant connected to Verbinal over MCP"))
        }
        func clip(_ text: String?, _ max: Int) -> String? {
            text.map { ToolFailureReason.clip($0.trimmingCharacters(in: .whitespacesAndNewlines), max: max) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let request = SessionApprovals.Request(
            id: session, client: context.client ?? "an unnamed client", mcpVersion: context.mcpVersion,
            agent: clip(args.agent, 80) ?? "an unnamed assistant", model: clip(args.model, 80),
            purpose: clip(args.purpose, 300), askedAt: Date())
        let already = await approvals.approval(for: session) != nil
        switch await approvals.ask(request) {
        case .allowed(let approval):
            if !already { await note(session, SessionLogLine.started(approval)) }
            let output = Output(session: session.uuidString, instructions: approval.instructions,
                                allowedAt: approval.allowedAt,
                                log: "get_session_log reads every entry of this session; explain_log_entry follows one.")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return .data((try? encoder.encode(output)) ?? Data())
        case .declined:
            await note(session, SessionLogLine.declined(request))
            return .failed(.sessionDeclined)
        case .abandoned:
            await note(session, SessionLogLine.abandoned(request))
            return .failed(.sessionRequired)
        }
    }
}
