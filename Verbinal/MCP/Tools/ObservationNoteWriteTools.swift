// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - update_observation_note

/// Update (or create) the user-authored note attached to an observation.
struct UpdateObservationNoteTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let publisher_id: String
        var text: String?
        var rating: Int?
        var tags: [String]?
    }

    struct Payload: Codable, Sendable {
        let publisherID: String
        let text: String?
        let rating: Int?
        let tags: [String]?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "update_observation_note",
        description: "Set the user's note for an observation: text body, 0-5 star rating, free-form tags. Any field may be omitted to leave it unchanged.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisher_id"],
          "properties": {
            "publisher_id": { "type": "string" },
            "text":         { "type": "string" },
            "rating":       { "type": "integer", "minimum": 0, "maximum": 5 },
            "tags":         { "type": "array", "items": { "type": "string" } }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        if let r = args.rating, !(0...5).contains(r) {
            throw ToolFailureReason.invalidArgument("rating must be 0-5")
        }
        var summary = "Update note for \(args.publisher_id)"
        if let text = args.text {
            let preview = String(text.prefix(40))
            summary += ": \(preview)"
        }
        return try ProposalPlan.encoding(
            kind: "update_observation_note",
            summary: summary,
            payload: Payload(
                publisherID: args.publisher_id,
                text: args.text,
                rating: args.rating,
                tags: args.tags
            )
        )
    }
}

struct UpdateObservationNoteApplier: ProposalApplier {
    let kind = "update_observation_note"
    let store: ObservationNoteStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(UpdateObservationNoteTool.Payload.self, from: proposal.payload)
        await MainActor.run {
            ObservationNoteApplyHelpers.applyOne(
                payload: payload,
                store: store,
                proposal: proposal
            )
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

// MARK: - bulk_update_observation_notes

/// Update notes on up to 50 observations as ONE proposal.
///
/// Closes F-15 from the 2026-04-30 astronomer workflow exercise:
/// annotating a 5-epoch time series cost 5 of 8 budget slots, even
/// though it's logically a single batched intent — same shape as the
/// existing `download_observations_bulk` does for downloads.
struct BulkUpdateObservationNotesTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    static let maxBatchSize = 50

    struct Args: Decodable, Sendable {
        let items: [UpdateObservationNoteTool.Args]
    }

    struct Payload: Codable, Sendable {
        let items: [UpdateObservationNoteTool.Payload]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "bulk_update_observation_notes",
        description: "Update notes on up to 50 observations as ONE proposal. Same per-item shape as `update_observation_note`. Use whenever annotating a sibling group (e.g. all 5 epochs of a time series) — costs one budget slot, lands all atomically.",
        schema: #"""
        {
          "type": "object",
          "required": ["items"],
          "properties": {
            "items": {
              "type": "array",
              "minItems": 1,
              "maxItems": 50,
              "items": { "type": "object" }
            }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.items.isEmpty else {
            throw ToolFailureReason.invalidArgument("items is empty")
        }
        guard args.items.count <= Self.maxBatchSize else {
            throw ToolFailureReason.invalidArgument(
                "max \(Self.maxBatchSize) items per bulk note update"
            )
        }
        for item in args.items {
            if let r = item.rating, !(0...5).contains(r) {
                throw ToolFailureReason.invalidArgument("rating must be 0-5")
            }
        }
        let payloads = args.items.map {
            UpdateObservationNoteTool.Payload(
                publisherID: $0.publisher_id,
                text: $0.text,
                rating: $0.rating,
                tags: $0.tags
            )
        }
        return try ProposalPlan.encoding(
            kind: "bulk_update_observation_notes",
            summary: "Update notes on \(payloads.count) observation\(payloads.count == 1 ? "" : "s")",
            payload: Payload(items: payloads)
        )
    }
}

struct BulkUpdateObservationNotesApplier: ProposalApplier {
    let kind = "bulk_update_observation_notes"
    let store: ObservationNoteStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(BulkUpdateObservationNotesTool.Payload.self, from: proposal.payload)
        await MainActor.run {
            for item in payload.items {
                ObservationNoteApplyHelpers.applyOne(
                    payload: item,
                    store: store,
                    proposal: proposal
                )
            }
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

/// Internals shared between the single and bulk appliers so a future
/// schema field on the note doesn't require updating two call sites.
@MainActor
enum ObservationNoteApplyHelpers {
    static func applyOne(
        payload: UpdateObservationNoteTool.Payload,
        store: ObservationNoteStore,
        proposal: PendingProposal
    ) {
        let existing = store.note(for: payload.publisherID)
        let now = Date()
        let merged = ObservationNote(
            publisherID: payload.publisherID,
            text: payload.text ?? existing?.text ?? "",
            rating: payload.rating ?? existing?.rating ?? 0,
            tags: payload.tags ?? existing?.tags ?? [],
            createdAt: existing?.createdAt ?? now,
            modifiedAt: now,
            agentAttribution: AgentAttribution.from(proposal: proposal)
        )
        store.save(merged)
    }
}
