// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - open_vospace_file

/// Download a VOSpace file and open it in the right viewer (FITS or
/// Cube) — the Storage browser's "Open in FITS Viewer" context action.
struct OpenVOSpaceFileTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let path: String
    }

    struct Payload: Codable, Sendable {
        let path: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "open_vospace_file",
        description: "Download a FITS file from VOSpace (path relative to the user's home, from `list_vospace_path`) and open it in the right viewer — 2D images route to the FITS Viewer; NAXIS≥3 files show the Open as… sheet (`get_current_view.pendingViewerChoice`) and this ack's `note` tells you to call `choose_viewer`. The Storage browser's \"Open in FITS Viewer\" action. Downloads to a temporary location; proposal-gated like other VOSpace transfers.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path": { "type": "string", "minLength": 1, "description": "VOSpace file path relative to the user's home." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let path = args.path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            throw ToolFailureReason.invalidArgument("path is empty")
        }
        guard !path.contains("..") else {
            throw ToolFailureReason.invalidArgument("path must not contain '..'")
        }
        return try ProposalPlan.encoding(
            kind: "open_vospace_file",
            summary: "Open VOSpace file in viewer: \(path)",
            payload: Payload(path: path)
        )
    }
}

struct OpenVOSpaceFileApplier: ProposalApplier, ResultReportingApplier {
    let kind = "open_vospace_file"
    /// Downloads the file and routes it into the appropriate viewer.
    /// Returns an agent note when the Open as… sheet is showing.
    let openFile: @Sendable (String) async throws -> String?
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(OpenVOSpaceFileTool.Payload.self, from: proposal.payload)
        let note = try await openFile(payload.path)
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        let extra = AutoAppliedAck.Extra(note: note)
        return (try? JSONEncoder().encode(extra)) ?? Data()
    }
}
