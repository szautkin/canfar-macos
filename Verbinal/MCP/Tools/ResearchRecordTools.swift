// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Research records without their file: keep an observation to read about
/// and download later, remove a file but keep the observation, and show a
/// record on the person's screen.

// MARK: - save_observation_to_research

struct SaveObservationToResearchTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    /// What is known of the observation; the rest comes from the search
    /// results or the publisher ID.
    struct Args: Codable, Sendable, Equatable {
        var publisherId: String
        var collection: String?
        var observationID: String?
        var targetName: String?
        var instrument: String?
        var filter: String?
        var ra: String?
        var dec: String?
        var startDate: String?
        var calLevel: String?
    }
    typealias Payload = Args

    let definition = AIToolDefinition.withStaticSchema(
        name: "save_observation_to_research",
        description: "Keep an observation in Research WITHOUT downloading its file — its details and a place for notes; the file can be downloaded later (download_observation, or Download in Research, into the same record). Details come from Research's record or the current search results when the observation is among them, otherwise from what you give here — and the archive's own record of the plane corrects and completes them (the collection and observation id are read from the publisher id when nothing else says). A malformed publisher id is refused. An observation already in Research is left as it is. Returns its downloaded_observation_id.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisherId"],
          "properties": {
            "publisherId":   { "type": "string", "minLength": 1 },
            "collection":    { "type": "string" },
            "observationID": { "type": "string" },
            "targetName":    { "type": "string" },
            "instrument":    { "type": "string" },
            "filter":        { "type": "string" },
            "ra":            { "type": "string" },
            "dec":           { "type": "string" },
            "startDate":     { "type": "string" },
            "calLevel":      { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let pid = args.publisherId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else { throw ToolFailureReason.invalidArgument("publisherId is required") }
        guard PublisherID(pid) != nil else { throw ToolFailureReason.invalidArgument(PublisherID.malformed(pid)) }
        var payload = args
        payload.publisherId = pid
        let label = [args.targetName, args.instrument].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        return try ProposalPlan.encoding(
            kind: "save_observation_to_research",
            summary: "Save \(label.isEmpty ? pid : "\(label) (\(pid))") to Research, without its file",
            payload: payload)
    }

    /// A record from what the arguments say, filling the collection and
    /// observation id from the publisher ID when they are not given.
    static func record(from args: Args) -> DownloadedObservation {
        let parsed = PublisherID(args.publisherId)
        func given(_ value: String?) -> String { value ?? "" }
        return DownloadedObservation(
            publisherID: args.publisherId,
            collection: args.collection ?? parsed?.collection ?? "",
            observationID: args.observationID ?? parsed?.observationID ?? "",
            targetName: given(args.targetName), instrument: given(args.instrument), filter: given(args.filter),
            ra: given(args.ra), dec: given(args.dec), startDate: given(args.startDate), calLevel: given(args.calLevel),
            localPath: "")
    }
}

struct SaveObservationToResearchApplier: ResultReportingApplier {
    let kind = "save_observation_to_research"
    /// Keeps the observation; returns its record and whether it is new.
    let save: @Sendable (SaveObservationToResearchTool.Payload, AgentAttribution?) async throws -> (id: UUID, added: Bool)
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(SaveObservationToResearchTool.Payload.self, from: proposal.payload)
        let (id, added) = try await save(payload, AgentAttribution.from(proposal: proposal))
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        let extra = added ? AutoAppliedAck.Extra(id: id.uuidString)
            : .unchanged(id: id.uuidString, "already in Research — left as it was")
        return (try? JSONEncoder().encode(extra)) ?? Data()
    }
}

// MARK: - remove_downloaded_file (destructive)

struct RemoveDownloadedFileTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Codable, Sendable { let id: String }
    typealias Payload = Args

    let definition = AIToolDefinition.withStaticSchema(
        name: "remove_downloaded_file",
        description: "Delete a Research observation's FILE from this computer while keeping the observation — its details and notes — so Download fetches it again into the same record. By downloaded_observation_id (or its first 8+ hex digits), publisher id, or observation id. To remove the observation itself, use delete_downloaded_observation.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": {
            "id": { "type": "string", "minLength": 1 }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let id = args.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ToolFailureReason.invalidArgument("id is required") }
        return try ProposalPlan.encoding(
            kind: "remove_downloaded_file",
            summary: "Remove the file of \(id) from this computer (keep it in Research)",
            payload: Args(id: id))
    }
}

struct RemoveDownloadedFileApplier: ProposalApplier {
    let kind = "remove_downloaded_file"
    let remove: @Sendable (String) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(RemoveDownloadedFileTool.Payload.self, from: proposal.payload)
        do {
            try await remove(payload.id)
        } catch let failure as ProposalApplyError {
            throw failure
        } catch {
            throw ProposalApplyError.backendError("file delete failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}

// MARK: - show_research_observation (live)

enum ResearchActions {
    struct ShowArgs: Decodable, Sendable { let id: String }

    static func show(perform: @escaping @Sendable (ShowArgs) async -> String?) -> LiveActionTool<ShowArgs> {
        LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "show_research_observation",
                description: "Show one of Research's observations on the person's screen: Research, with it selected and its detail open, as a click on it does. `id` is its downloaded_observation_id (or its first 8+ hex digits), its publisher id, or its observation id. Changes nothing stored. Live-applied; no proposal.",
                schema: #"""
                {
                  "type": "object",
                  "required": ["id"],
                  "properties": {
                    "id": { "type": "string", "minLength": 1 }
                  },
                  "additionalProperties": false
                }
                """#),
            perform: perform)
    }
}
