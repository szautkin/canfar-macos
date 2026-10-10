// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - clear_research_archive (destructive)

/// Wipe all locally-stored downloaded observation metadata. Doesn't
/// touch local files — the user keeps the downloads on disk; only the
/// archive index is cleared.
struct ClearResearchArchiveTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    typealias Args = EmptyArgs

    struct Payload: Codable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "clear_research_archive",
        description: "Remove ALL downloaded-observation metadata records. Does not touch local files.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: EmptyArgs, context: AIToolContext) async throws -> ProposalPlan {
        try ProposalPlan.encoding(
            kind: "clear_research_archive",
            summary: "Clear ALL research archive records",
            payload: Payload()
        )
    }
}

struct ClearResearchArchiveApplier: ProposalApplier {
    let kind = "clear_research_archive"
    let store: ObservationStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        await MainActor.run {
            store.clear()
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}
