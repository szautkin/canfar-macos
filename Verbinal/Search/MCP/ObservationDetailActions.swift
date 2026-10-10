// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

enum ObservationDetailActions {
    struct RowIDArgs: Decodable, Sendable { let rowID: String }
    struct RowArgs: Decodable, Sendable { let row: Int }
    struct PublisherArgs: Decodable, Sendable { let publisherId: String }

    static func openByRowID(perform: @escaping @Sendable (RowIDArgs) async -> String?) -> LiveActionTool<RowIDArgs> {
        LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "open_observation_detail",
                description: "Open the observation detail sheet (Overview / Coverage / Files / Provenance / Raw) for one results-table row — the user's double-click. `rowID` comes from `get_search_results`. Navigates to Search ▸ Results so the user sees it. Live-applied; no proposal.",
                schema: #"""
                {
                  "type": "object",
                  "required": ["rowID"],
                  "properties": { "rowID": { "type": "string", "description": "Stable row id from get_search_results." } },
                  "additionalProperties": false
                }
                """#),
            perform: perform)
    }

    static func openByRow(perform: @escaping @Sendable (RowArgs) async -> String?) -> LiveActionTool<RowArgs> {
        LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "show_search_row_detail",
                description: "Open the observation detail sheet for a row of the results table as it is on screen — the same view a click on the row gives. `row` is 0-based within the page shown. Live-applied; no proposal.",
                schema: #"""
                {
                  "type": "object",
                  "required": ["row"],
                  "properties": { "row": { "type": "integer", "minimum": 0 } },
                  "additionalProperties": false
                }
                """#),
            perform: perform)
    }

    static func openByPublisherID(perform: @escaping @Sendable (PublisherArgs) async -> String?) -> LiveActionTool<PublisherArgs> {
        LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "show_observation_detail",
                description: "Open one observation's detail sheet (overview, coverage, files, provenance, raw metadata) by its publisher id — the publisherID column of a search result. The observation must be among the current search results (run a search for it first, e.g. set_search_form with observationID); unlike get_observation_caom2 this puts it on the user's screen. Live-applied; no proposal.",
                schema: #"""
                {
                  "type": "object",
                  "required": ["publisherId"],
                  "properties": { "publisherId": { "type": "string", "minLength": 1 } },
                  "additionalProperties": false
                }
                """#),
            perform: perform)
    }
}
