// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - export_research_bundle

/// Export the user's research archive as a portable bundle in Downloads,
/// optionally including copies of the downloaded files and optionally
/// uploading the bundle to VOSpace afterwards.
struct ExportResearchBundleTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        var includeFileCopies: Bool?
        var uploadToVOSpace: Bool?
    }

    struct Payload: Codable, Sendable {
        let includeFileCopies: Bool
        let uploadToVOSpace: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "export_research_bundle",
        description: "Export the research archive as a portable bundle in the user's Downloads folder. `includeFileCopies` also copies the downloaded data files into the bundle (larger, but self-contained); `uploadToVOSpace` additionally uploads the finished bundle to the user's VOSpace. Both default to false.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "includeFileCopies": { "type": "boolean", "description": "Also copy the downloaded data files into the bundle. Default false." },
            "uploadToVOSpace":   { "type": "boolean", "description": "Upload the finished bundle to the user's VOSpace. Default false." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let includeFileCopies = args.includeFileCopies ?? false
        let uploadToVOSpace = args.uploadToVOSpace ?? false
        var summary = "Export research bundle to Downloads"
        if includeFileCopies {
            summary += " (with file copies)"
        }
        if uploadToVOSpace {
            summary += " + upload to VOSpace"
        }
        return try ProposalPlan.encoding(
            kind: "export_research_bundle",
            summary: summary,
            payload: Payload(
                includeFileCopies: includeFileCopies,
                uploadToVOSpace: uploadToVOSpace
            )
        )
    }
}

/// Concrete handler that runs when the user clicks Apply on an
/// `export_research_bundle` proposal (or immediately under auto-apply).
struct ExportResearchBundleApplier: ProposalApplier {
    let kind = "export_research_bundle"
    let run: @Sendable (_ includeFileCopies: Bool, _ uploadToVOSpace: Bool) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(ExportResearchBundleTool.Payload.self, from: proposal.payload)
        do {
            try await run(payload.includeFileCopies, payload.uploadToVOSpace)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("export failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
