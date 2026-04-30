// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// A user-authored note attached to an observation (keyed by publisherID so the note
/// survives re-download or local file moves — notes live on the *observation*, not the file).
struct ObservationNote: Codable, Equatable {
    var publisherID: String
    var text: String
    /// Quality rating, 0 = unrated, 1–5 = star rating.
    var rating: Int
    /// Free-form tags (e.g. "usable", "calibration", "reprocess").
    var tags: [String]
    var createdAt: Date
    var modifiedAt: Date
    /// Stamp set when the most recent edit came from an MCP-connected
    /// agent. The note's content is the merged result of any chain of
    /// edits (user + agent), so this points at the *latest* agent edit
    /// only — historical attribution lives in the activity feed.
    var agentAttribution: AgentAttribution?

    init(publisherID: String,
         text: String = "",
         rating: Int = 0,
         tags: [String] = [],
         createdAt: Date = Date(),
         modifiedAt: Date = Date(),
         agentAttribution: AgentAttribution? = nil) {
        self.publisherID = publisherID
        self.text = text
        self.rating = rating
        self.tags = tags
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.agentAttribution = agentAttribution
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rating == 0 && tags.isEmpty
    }
}
