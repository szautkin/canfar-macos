// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - renew_session

/// Renew (extend the expiry of) a running Skaha session by id.
struct RenewSessionTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Payload: Codable, Sendable {
        let id: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "renew_session",
        description: "Renew (extend the expiry time of) a running Skaha session by id — interactive or headless. Non-destructive; runs immediately when auto-apply is on, otherwise queues to the proposal strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": {
            "id": { "type": "string", "description": "Skaha session id, as returned by list_sessions." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let id = args.id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            throw ToolFailureReason.invalidArgument("id is empty")
        }
        return try ProposalPlan.encoding(
            kind: "renew_session",
            summary: "Renew (extend) session \(id)",
            payload: Payload(id: id)
        )
    }
}

/// Concrete handler that runs when the user clicks Apply on a
/// `renew_session` proposal (or immediately under auto-apply).
struct RenewSessionApplier: ProposalApplier {
    let kind = "renew_session"
    let renew: @Sendable (String) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(RenewSessionTool.Payload.self, from: proposal.payload)
        do {
            try await renew(payload.id)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("renew failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
