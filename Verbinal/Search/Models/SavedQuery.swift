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
    /// Provenance stamp when an MCP-connected agent created this entry
    /// via the proposal flow. `nil` for entries the user authored
    /// directly. Drives the wand badge in the saved-queries list.
    var agentAttribution: AgentAttribution?
}
