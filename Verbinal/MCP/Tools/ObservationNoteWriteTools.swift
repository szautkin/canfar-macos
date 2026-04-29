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

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(UpdateObservationNoteTool.Payload.self, from: proposal.payload)
        await MainActor.run {
            let existing = store.note(for: payload.publisherID)
            let now = Date()
            let merged = ObservationNote(
                publisherID: payload.publisherID,
                text: payload.text ?? existing?.text ?? "",
                rating: payload.rating ?? existing?.rating ?? 0,
                tags: payload.tags ?? existing?.tags ?? [],
                createdAt: existing?.createdAt ?? now,
                modifiedAt: now
            )
            store.save(merged)
        }
    }
}
