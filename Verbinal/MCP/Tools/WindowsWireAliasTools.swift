// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// Thin Windows-wire tools that aren't 1:1 renames of a Mac tool.
// 1:1 renames use `AliasedToolBox` in AppState+AgentTools.

// MARK: - run_search

/// Execute the current Search form (the Search button) — Windows wire name.
struct RunSearchTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Output: Encodable, Sendable {
        let applied: Bool
        let executed: Bool
        let resultCount: Int?
        let searchError: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "run_search",
        description: "Press the Search button: run the current Search form (form → ADQL → Results tab + Recent Searches entry). Equivalent to `set_search_form` with `execute: true` and no field patches. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let execute: @Sendable () async -> SetSearchFormTool.Outcome

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let outcome = await execute()
        if let message = outcome.error {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(
                applied: true,
                executed: outcome.executed,
                resultCount: outcome.resultCount,
                searchError: outcome.searchError))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - set_search_constraints

/// Patch only the data-train facet selections — Windows wire name.
struct SetSearchConstraintsTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var bands: [String]?
        var collections: [String]?
        var instruments: [String]?
        var filters: [String]?
        var calLevels: [String]?
        var dataTypes: [String]?
        var obsTypes: [String]?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_search_constraints",
        description: "Set/clear the Search form's Additional Constraints data-train facet selections (bands, collections, instruments, filters, calLevels, dataTypes, obsTypes). Arrays replace the current selection; setting an upstream column clears downstream columns not provided in the same call (UI cascade rule). Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "bands":        { "type": "array", "items": { "type": "string" } },
            "collections":  { "type": "array", "items": { "type": "string" } },
            "instruments":  { "type": "array", "items": { "type": "string" } },
            "filters":      { "type": "array", "items": { "type": "string" } },
            "calLevels":    { "type": "array", "items": { "type": "string" } },
            "dataTypes":    { "type": "array", "items": { "type": "string" } },
            "obsTypes":     { "type": "array", "items": { "type": "string" } }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (SetSearchFormTool.Args) async -> SetSearchFormTool.Outcome

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        var patch = SetSearchFormTool.Args()
        patch.bands = args.bands
        patch.collections = args.collections
        patch.instruments = args.instruments
        patch.filters = args.filters
        patch.calLevels = args.calLevels
        patch.dataTypes = args.dataTypes
        patch.obsTypes = args.obsTypes
        let outcome = await apply(patch)
        if let message = outcome.error {
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

// MARK: - execute_adql_query

/// Run the ADQL editor contents — Windows wire name.
struct ExecuteADQLQueryTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var adql: String?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let adql: String
        let executed: Bool
        let resultCount: Int?
        let searchError: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "execute_adql_query",
        description: "Execute ADQL from the editor tab. Optional `adql` replaces the editor text first; omit to run the current editor contents. Switches to the ADQL tab. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "adql": { "type": "string", "minLength": 1 }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (SetADQLEditorTool.Args) async -> SetADQLEditorTool.Outcome

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        var patch = SetADQLEditorTool.Args()
        patch.adql = args.adql
        patch.execute = true
        let outcome = await apply(patch)
        if let message = outcome.error {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(
                applied: true,
                adql: outcome.adql,
                executed: outcome.executed,
                resultCount: outcome.resultCount,
                searchError: outcome.searchError))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - load_recent_search / run_saved_query

struct LoadRecentSearchTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        /// 0-based index into `list_recent_searches`, or a recent-search UUID.
        var index: Int?
        var recentSearchID: String?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let target: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "load_recent_search",
        description: "Load a recent search into the Search form (side-panel Load). Pass `index` (0-based from `list_recent_searches`) or `recentSearchID` (UUID). Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "index": { "type": "integer", "minimum": 0 },
            "recentSearchID": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (Args) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if args.index == nil && args.recentSearchID == nil {
            return .failed(.invalidArgument("provide index or recentSearchID"))
        }
        if let message = await apply(args) {
            return .failed(.backendError(message))
        }
        let target = args.recentSearchID ?? "index \(args.index ?? -1)"
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true, target: target))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

struct RunSavedQueryTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var name: String?
        var savedQueryID: String?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let target: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "run_saved_query",
        description: "Load a saved ADQL query into the editor and run it (side-panel Run). Pass `name` (exact title from `list_saved_queries`) or `savedQueryID` (UUID). Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "name": { "type": "string", "minLength": 1 },
            "savedQueryID": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (Args) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if args.name == nil && args.savedQueryID == nil {
            return .failed(.invalidArgument("provide name or savedQueryID"))
        }
        if let message = await apply(args) {
            return .failed(.backendError(message))
        }
        let target = args.name ?? args.savedQueryID ?? ""
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true, target: target))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
