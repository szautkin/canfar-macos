// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `set_vospace_acl` — change who can access a VOSpace node (Windows
/// parity, MCP-only on both platforms; the Storage UI shows ACLs but the
/// mutation lives here). Three-valued per dimension so an agent can adjust
/// one axis without clobbering the others.
struct SetVOSpaceACLTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let path: String
        let groupRead: [String]?
        let groupWrite: [String]?
        let isPublic: Bool?
    }

    struct Payload: Codable, Sendable {
        let path: String
        let groupRead: [String]?
        let groupWrite: [String]?
        let isPublic: Bool?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_vospace_acl",
        description: "Change who can access a VOSpace file or folder in the user's home tree. groupRead/groupWrite take full GMS group URIs (ivo://cadc.nrc.ca/gms?GroupName): omit a field to leave it unchanged, pass [] to revoke all groups, or pass values to REPLACE the whole list. isPublic true makes the node world-readable. Proposal-gated.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path": {
              "type": "string",
              "description": "Node path relative to the user's VOSpace home, e.g. \"results/stack.fits\"."
            },
            "groupRead": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Full GMS group URIs granted READ. Omit = unchanged; [] = revoke all; values replace the whole list."
            },
            "groupWrite": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Full GMS group URIs granted WRITE. Omit = unchanged; [] = revoke all; values replace the whole list."
            },
            "isPublic": {
              "type": "boolean",
              "description": "true = world-readable, false = not public. Omit to leave unchanged."
            }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let path = args.path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            throw ToolFailureReason.invalidArgument("path is required")
        }
        guard !path.split(separator: "/").contains("..") else {
            throw ToolFailureReason.invalidArgument("path must not contain '..' segments")
        }
        guard args.groupRead != nil || args.groupWrite != nil || args.isPublic != nil else {
            throw ToolFailureReason.invalidArgument(
                "specify at least one of groupRead, groupWrite, or isPublic to change")
        }

        // Spell out the resulting ACL so the proposal strip reads as a
        // complete statement of what Apply will do.
        var parts: [String] = []
        if let read = args.groupRead {
            parts.append(read.isEmpty ? "read: revoke all groups" : "read: \(read.joined(separator: ", "))")
        }
        if let write = args.groupWrite {
            parts.append(write.isEmpty ? "write: revoke all groups" : "write: \(write.joined(separator: ", "))")
        }
        if let pub = args.isPublic {
            parts.append("public: \(pub ? "yes (world-readable)" : "no")")
        }
        return try ProposalPlan.encoding(
            kind: "set_vospace_acl",
            summary: "Set ACL on \(path) → \(parts.joined(separator: "; "))",
            payload: Payload(path: path, groupRead: args.groupRead,
                             groupWrite: args.groupWrite, isPublic: args.isPublic)
        )
    }
}

struct SetVOSpaceACLApplier: ProposalApplier {
    let kind = "set_vospace_acl"
    let set: @Sendable (_ path: String, _ groupRead: [String]?, _ groupWrite: [String]?, _ isPublic: Bool?) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(SetVOSpaceACLTool.Payload.self, from: proposal.payload)
        do {
            try await set(payload.path, payload.groupRead, payload.groupWrite, payload.isPublic)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("set ACL failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
