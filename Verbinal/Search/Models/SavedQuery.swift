// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// A saved ADQL query for re-use.
struct SavedQuery: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var adql: String
    var savedAt: Date = Date()
    /// Free-form rationale — why this query matters, what to look
    /// for in its results, links to upstream design notes. Optional;
    /// agent-saved queries (post-2026-04-29 platform review F-6)
    /// populate this from the proposal payload, hand-saved ones may
    /// leave it empty.
    var description: String = ""
    /// Free-form tags for grouping / filtering, e.g.
    /// `["snls", "cfhtls-d2", "r-band", "time-series"]`. Same shape
    /// as `ObservationNote.tags` so the two surfaces compose
    /// naturally — a researcher's tag vocabulary travels across them.
    var tags: [String] = []
    /// Provenance stamp when an MCP-connected agent created this entry
    /// via the proposal flow. `nil` for entries the user authored
    /// directly. Drives the wand badge in the saved-queries list.
    var agentAttribution: AgentAttribution?
}
