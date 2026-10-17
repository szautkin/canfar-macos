// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// A Research file between this Mac and the person's CANFAR storage (the
/// person's request, 2026-10-09), as the Files section of a record moves
/// it: copied either way, and a copy removed only while the other is there.

enum ResearchFileTransferTools {
    /// A record, and one of its files by name; nil for its main file.
    struct Args: Codable, Sendable, Equatable {
        let id: String
        var file: String?
    }

    static let schema = #"""
    {
      "type": "object",
      "required": ["id"],
      "properties": {
        "id": { "type": "string", "minLength": 1, "description": "The record's downloaded_observation_id (or its first 8+ hex digits), publisher id, or observation id." },
        "file": { "type": "string", "minLength": 1, "description": "One of the record's files by name (get_downloaded_observation lists them); omit for its main file." }
      },
      "additionalProperties": false
    }
    """#

    /// Judges what is asked against where the file is, when it is asked:
    /// throws what cannot be done, saying why.
    typealias Check = @Sendable (_ kind: String, _ args: Args) async throws -> Void

    static func plan(_ kind: String, _ args: Args, check: Check?, _ summary: (String) -> String) async throws -> ProposalPlan {
        let id = args.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ToolFailureReason.invalidArgument("id is required") }
        let file = args.file?.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = file?.isEmpty == false ? file : nil
        let asked = Args(id: id, file: named)
        // Refused now, not once the person approved it (plan 44 D): a removal
        // of a file's last copy went to Pending, saying the other copy stays.
        try await check?(kind, asked)
        return try ProposalPlan.encoding(kind: kind, summary: summary(named.map { "\($0) of \(id)" } ?? "the file of \(id)"),
                                         payload: asked)
    }
}

// MARK: - send_research_file_to_storage

struct SendResearchFileToStorageTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    typealias Args = ResearchFileTransferTools.Args

    var check: ResearchFileTransferTools.Check?
    let definition = AIToolDefinition.withStaticSchema(
        name: "send_research_file_to_storage",
        description: "Copy one of a Research record's files from this Mac to the person's CANFAR storage, into `Verbinal-Results/research/`; it stays on this Mac too. A file of that name already there is never written over: the same size is taken for this one, another is refused. Needs CANFAR sign-in. Answers the storage path (`file`); list_downloaded_observations then says the file's `places` is `both`. To move it, follow with remove_research_file_from_mac.",
        schema: ResearchFileTransferTools.schema)

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        try await ResearchFileTransferTools.plan("send_research_file_to_storage", args, check: check) { "Send \($0) to your storage" }
    }
}

// MARK: - get_research_file_from_storage

struct GetResearchFileFromStorageTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    typealias Args = ResearchFileTransferTools.Args

    var check: ResearchFileTransferTools.Check?
    let definition = AIToolDefinition.withStaticSchema(
        name: "get_research_file_from_storage",
        description: "Copy one of a Research record's files from the person's CANFAR storage back to this Mac, into their download folder, as the record's file again; it stays in storage too. For a file whose `places` is `storage`. Needs CANFAR sign-in. Answers where it is on this Mac (`file`). To move it, follow with remove_research_file_from_storage.",
        schema: ResearchFileTransferTools.schema)

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        try await ResearchFileTransferTools.plan("get_research_file_from_storage", args, check: check) { "Get \($0) from your storage to this Mac" }
    }
}

// MARK: - remove_research_file_from_mac (destructive)

struct RemoveResearchFileFromMacTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive
    typealias Args = ResearchFileTransferTools.Args

    var check: ResearchFileTransferTools.Check?
    let definition = AIToolDefinition.withStaticSchema(
        name: "remove_research_file_from_mac",
        description: "Delete the copy on this Mac of a Research record's file that is in the person's storage too (`places` `both`); the copy in storage stays, and get_research_file_from_storage brings it back. Refused for a file with no copy in storage — that would lose it (remove_downloaded_file removes such a file, as the person decides).",
        schema: ResearchFileTransferTools.schema)

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        try await ResearchFileTransferTools.plan("remove_research_file_from_mac", args, check: check) { "Remove \($0) from this Mac (it stays in your storage)" }
    }
}

// MARK: - remove_research_file_from_storage (destructive)

struct RemoveResearchFileFromStorageTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive
    typealias Args = ResearchFileTransferTools.Args

    var check: ResearchFileTransferTools.Check?
    let definition = AIToolDefinition.withStaticSchema(
        name: "remove_research_file_from_storage",
        description: "Delete the copy in the person's CANFAR storage of a Research record's file that is on this Mac too (`places` `both`, the Mac copy there); the copy on this Mac stays. Refused for a file with no copy on this Mac — that would lose it. Needs CANFAR sign-in.",
        schema: ResearchFileTransferTools.schema)

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        try await ResearchFileTransferTools.plan("remove_research_file_from_storage", args, check: check) { "Remove \($0) from your storage (it stays on this Mac)" }
    }
}

// MARK: - Applier

/// Applies one of the four: `run` does it and answers what it came to.
struct ResearchFileTransferApplier: ResultReportingApplier {
    let kind: String
    let run: @Sendable (ResearchFileTransferTools.Args) async throws -> AutoAppliedAck.Extra
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(ResearchFileTransferTools.Args.self, from: proposal.payload)
        let extra: AutoAppliedAck.Extra
        do {
            extra = try await run(payload)
        } catch let failure as ProposalApplyError {
            throw failure
        } catch {
            throw ProposalApplyError.backendError(error.localizedDescription)
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        return (try? JSONEncoder().encode(extra)) ?? Data()
    }
}
