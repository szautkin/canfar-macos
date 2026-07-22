// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Results-table control tools — read the in-app results the user is
/// looking at (with their live sort/filter/pagination applied) and steer
/// the table the way the user does: sort, per-column filters, page,
/// page size, column visibility, display units, and the row detail
/// sheet. Capability closures are injected by the app at wiring time.

// MARK: - get_search_results

/// Read the in-app results table: state + a page of rows.
struct GetSearchResultsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        /// 0-based page to return; defaults to the page the user is on.
        var page: Int?
        /// Include hidden columns too (default: visible columns only).
        var allColumns: Bool?
        /// Cap on returned rows (default 200, max 1000).
        var maxRows: Int?
        /// Skip row data entirely — state + columns only.
        var includeRows: Bool?
    }

    struct Output: Encodable, Sendable {
        let hasResults: Bool
        let adqlQuery: String
        let totalRows: Int
        let filteredCount: Int
        let maxRecordReached: Bool
        let currentPage: Int
        let totalPages: Int
        let rowsPerPage: Int
        let sortColumnID: String?
        let sortAscending: Bool
        let activeFilters: [String: String]
        let columns: [Column]
        /// The page of rows actually returned (may differ from the
        /// user's current page when `page` was passed). Row values are
        /// raw server strings, positional per `columns`.
        let returnedPage: Int?
        let rowIDs: [String]
        let rows: [[String]]
        let rowsTruncated: Bool

        struct Column: Encodable, Sendable {
            let id: String
            let label: String
            let kind: String
            let visible: Bool
            let selectedUnit: String?
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_search_results",
        description: "Read the in-app Search results table exactly as the user sees it: the loaded query, row counts (total + after the user's live per-column filters), sort state, active filters, pagination, and column metadata (id, label, kind, visibility, selected display unit). Returns one page of raw row values (positional per `columns`) plus stable `rowIDs` for `open_observation_detail`. Pass `page` to read a different page than the one on screen, `allColumns: true` to include hidden columns, `includeRows: false` for state only. Rows are capped by `maxRows` (default 200, max 1000).",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "page":        { "type": "integer", "minimum": 0, "description": "0-based page; defaults to the user's current page." },
            "allColumns":  { "type": "boolean", "description": "Include hidden columns (default false)." },
            "maxRows":     { "type": "integer", "minimum": 1, "maximum": 1000, "description": "Row cap for this response (default 200)." },
            "includeRows": { "type": "boolean", "description": "Set false for state + columns only." }
          },
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable (Args) async -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        await snapshot(args)
    }
}

// MARK: - set_results_view

/// Steer the results table: sort, filters, pagination, column
/// visibility, display units. Live-applied view state.
struct SetResultsViewTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var sortColumnID: String?
        var sortAscending: Bool?
        var clearSort: Bool?
        /// Merge semantics: provided keys are set; empty-string values
        /// clear that column's filter.
        var filters: [String: String]?
        var clearFilters: Bool?
        var page: Int?
        var rowsPerPage: Int?
        /// Exact set of visible column ids (unlisted columns hide).
        var visibleColumns: [String]?
        var resetColumnVisibility: Bool?
        /// columnID → unitID for multi-unit columns.
        var columnUnits: [String: String]?
    }

    enum ApplyResult: Sendable {
        case applied(Summary)
        case rejected(String)

        struct Summary: Sendable {
            let filteredCount: Int
            let currentPage: Int
            let totalPages: Int
        }
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let filteredCount: Int
        let currentPage: Int
        let totalPages: Int
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_search_results_view",
        description: "Steer the in-app Search results table the way the user does — all fields optional, provide only what should change. `sortColumnID` sorts (with `sortAscending`, default true); `clearSort` removes sorting. `filters` merges per-column filter text (same syntax the user types: substrings, or `>`, `<`, `..` on numeric columns; empty string clears a column); `clearFilters` removes all. `page` (0-based) and `rowsPerPage` (50/100/500, or 0 for all — capped at 2000) paginate. `visibleColumns` sets the exact visible set; `resetColumnVisibility` restores defaults. `columnUnits` maps columnID → unitID for multi-unit columns. Returns the resulting filtered count and pagination. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "sortColumnID":  { "type": "string", "description": "Column id to sort by." },
            "sortAscending": { "type": "boolean", "description": "Sort direction (default true when sortColumnID is set)." },
            "clearSort":     { "type": "boolean", "description": "Remove sorting." },
            "filters":       { "type": "object", "additionalProperties": { "type": "string" }, "description": "columnID → filter text; empty string clears that column." },
            "clearFilters":  { "type": "boolean", "description": "Remove every column filter." },
            "page":          { "type": "integer", "minimum": 0, "description": "0-based page to show." },
            "rowsPerPage":   { "type": "integer", "enum": [50, 100, 500, 0], "description": "Rows per page; 0 = all (capped at 2000)." },
            "visibleColumns": { "type": "array", "items": { "type": "string" }, "description": "Exact set of visible column ids." },
            "resetColumnVisibility": { "type": "boolean", "description": "Restore default column visibility." },
            "columnUnits":   { "type": "object", "additionalProperties": { "type": "string" }, "description": "columnID → unitID for multi-unit columns." }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (Args) async -> ApplyResult

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        switch await apply(args) {
        case .rejected(let message):
            return .failed(.invalidArgument(message))
        case .applied(let summary):
            do {
                let bytes = try JSONEncoder().encode(Output(
                    applied: true,
                    filteredCount: summary.filteredCount,
                    currentPage: summary.currentPage,
                    totalPages: summary.totalPages))
                return .data(bytes)
            } catch {
                return .failed(.backendError("\(error)"))
            }
        }
    }
}

// MARK: - open_observation_detail

/// Open the observation detail sheet for a results row — the user's
/// double-click.
struct OpenObservationDetailTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let rowID: String
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "open_observation_detail",
        description: "Open the observation detail sheet (Overview / Coverage / Files / Provenance / Raw) for one results-table row — the user's double-click. `rowID` comes from `get_search_results`. Navigates to Search ▸ Results so the user sees it. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["rowID"],
          "properties": {
            "rowID": { "type": "string", "description": "Stable row id from get_search_results." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Returns an error message on failure, or nil when the sheet opened.
    let open: @Sendable (String) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if let message = await open(args.rowID) {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
