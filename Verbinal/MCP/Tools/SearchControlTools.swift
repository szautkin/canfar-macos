// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Search-form control tools — read and steer the live search form the
/// user sees: constraint fields, the data-train cascade, the ADQL editor,
/// the Search/Results/ADQL sub-tab, quick-search links, and the
/// recent-searches side panel. Capability closures are injected by the
/// app at wiring time; the tools themselves stay UI-framework-free.

// MARK: - get_search_form

/// Read the live search form: every constraint field, data-train
/// selections, resolver status, the selected sub-tab, and the ADQL the
/// form would generate.
struct GetSearchFormTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        // Observation constraints
        let observationID: String
        let piName: String
        let proposalID: String
        let proposalTitle: String
        let proposalKeywords: String
        let dataRelease: String
        let publicOnly: Bool
        let intent: String

        // Spatial constraints
        let target: String
        let resolver: String
        let pixelScale: String
        let resolverStatus: String
        let resolvedRA: String?
        let resolvedDec: String?

        // Temporal constraints
        let observationDate: String
        let datePreset: String
        let integrationTime: String
        let timeSpan: String

        // Spectral constraints
        let spectralCoverage: String
        let spectralSampling: String
        let resolvingPower: String
        let bandpassWidth: String
        let restFrameEnergy: String

        // Data-train (additional constraints) multi-selections
        let bands: [String]
        let collections: [String]
        let instruments: [String]
        let filters: [String]
        let calLevels: [String]
        let dataTypes: [String]
        let obsTypes: [String]

        // Meta
        let selectedTab: String
        let isSearching: Bool
        let searchError: String?
        /// The ADQL `executeSearch` would run right now.
        let generatedADQL: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_search_form",
        description: "Read the live Search form the user sees: every constraint field (observation, spatial, temporal, spectral), the data-train multi-selections (bands/collections/instruments/filters/calLevels/dataTypes/obsTypes), target-resolver status, the selected sub-tab (search/results/adql), whether a search is running, and `generatedADQL` — the query the form would execute right now. Use with `set_search_form` to fill the form the same way the user would.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await snapshot()
    }
}

// MARK: - set_search_form

/// Fill the live search form's fields (any subset), optionally executing
/// the search — exactly what the user does by typing and pressing Search.
/// Live-applied view state; no proposal.
struct SetSearchFormTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        // Observation
        var observationID: String?
        var piName: String?
        var proposalID: String?
        var proposalTitle: String?
        var proposalKeywords: String?
        var dataRelease: String?
        var publicOnly: Bool?
        var intent: String?
        // Spatial
        var target: String?
        var resolver: String?
        var pixelScale: String?
        // Temporal
        var observationDate: String?
        var datePreset: String?
        var integrationTime: String?
        var timeSpan: String?
        // Spectral
        var spectralCoverage: String?
        var spectralSampling: String?
        var resolvingPower: String?
        var bandpassWidth: String?
        var restFrameEnergy: String?
        // Data train
        var bands: [String]?
        var collections: [String]?
        var instruments: [String]?
        var filters: [String]?
        var calLevels: [String]?
        var dataTypes: [String]?
        var obsTypes: [String]?
        // Action
        var execute: Bool?

        init() {}
    }

    /// What the wiring reports back after applying (and optionally
    /// executing) the form change.
    struct Outcome: Sendable {
        var error: String? = nil
        var executed: Bool = false
        var resultCount: Int? = nil
        var searchError: String? = nil
        /// The person pressed Cancel while it ran.
        var cancelled: Bool = false
    }

    /// Also `run_search`'s reply — the same button, reached two ways.
    struct Output: Encodable, Sendable {
        let applied: Bool
        let executed: Bool
        let resultCount: Int?
        let searchError: String?
        let cancelled: Bool

        init(_ outcome: Outcome) {
            applied = true
            executed = outcome.executed
            resultCount = outcome.resultCount
            searchError = outcome.searchError
            cancelled = outcome.cancelled
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_search_form",
        description: "Fill the live Search form's fields — the same fields the user types into. All fields optional; provide only what should change. Field syntax matches the UI: ranges like `2020..2021`, operators like `> 2019`, wildcards like `ia*`. Data-train arrays (bands, collections, instruments, filters, calLevels, dataTypes, obsTypes) replace the current selection; setting an upstream column clears downstream columns not provided in the same call (the UI's cascade rule). Pass `execute: true` to run the search afterwards (results land in the Results tab, and the search is auto-saved to Recent Searches like a user-run search). Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "observationID":    { "type": "string" },
            "piName":           { "type": "string" },
            "proposalID":       { "type": "string" },
            "proposalTitle":    { "type": "string" },
            "proposalKeywords": { "type": "string" },
            "dataRelease":      { "type": "string" },
            "publicOnly":       { "type": "boolean" },
            "intent":           { "type": "string", "enum": ["any", "science", "calibration"] },
            "target":           { "type": "string", "description": "Target name or coordinates, as the user would type them." },
            "resolver":         { "type": "string", "enum": ["all", "simbad", "ned", "vizier", "none"] },
            "pixelScale":       { "type": "string" },
            "observationDate":  { "type": "string" },
            "datePreset":       { "type": "string", "enum": ["none", "past24Hours", "pastWeek", "pastMonth"] },
            "integrationTime":  { "type": "string" },
            "timeSpan":         { "type": "string" },
            "spectralCoverage": { "type": "string" },
            "spectralSampling": { "type": "string" },
            "resolvingPower":   { "type": "string" },
            "bandpassWidth":    { "type": "string" },
            "restFrameEnergy":  { "type": "string" },
            "bands":       { "type": "array", "items": { "type": "string" } },
            "collections": { "type": "array", "items": { "type": "string" } },
            "instruments": { "type": "array", "items": { "type": "string" } },
            "filters":     { "type": "array", "items": { "type": "string" } },
            "calLevels":   { "type": "array", "items": { "type": "string" } },
            "dataTypes":   { "type": "array", "items": { "type": "string" } },
            "obsTypes":    { "type": "array", "items": { "type": "string" } },
            "execute":     { "type": "boolean", "description": "Run the search after applying the fields." }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (Args) async -> Outcome

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        let outcome = await apply(args)
        if let message = outcome.error {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(outcome))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - reset_search_form

/// Clear every search-form field — the form's Reset button.
struct ResetSearchFormTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Output: Encodable, Sendable {
        let applied: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "reset_search_form",
        description: "Clear every Search form field and data-train selection — the form's Reset button. Does not touch loaded results, saved queries, or recent searches. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let reset: @Sendable () async -> Void

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        await reset()
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - cancel_search

/// The Cancel button beside the search spinner (form and ADQL editor).
struct CancelSearchTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Output: Encodable, Sendable {
        /// False when no search was running — nothing was stopped.
        let cancelled: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "cancel_search",
        description: "Stop the search that is running — the Cancel button beside the Search spinner, on the form and in the ADQL editor. The results already shown stay, and a cancelled search is not kept in Recent Searches. `cancelled` is false when no search was running. A `run_search` / `execute_adql_query` that was waiting reports `cancelled: true`. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let cancel: @Sendable () async -> Bool

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let stopped = await cancel()
        do {
            return .data(try JSONEncoder().encode(Output(cancelled: stopped)))
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - get_data_train_options

/// Read the data-train cascade's available options per column, filtered
/// by the current upstream selections (what the user sees in the
/// "Additional Constraints" checkboxes).
struct GetDataTrainOptionsTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let columns: [Column]
        let lastRefreshedISO: String?
        let isRefreshing: Bool
        let error: String?

        struct Column: Encodable, Sendable {
            let index: Int
            let id: String
            let title: String
            let options: [String]
            let selected: [String]
            let truncated: Bool
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_search_constraints",
        description: "Read the Search form's Additional Constraints data-train cascade: for each of the 7 columns (band, collection, instrument, filter, calLevel, dataType, obsType) the currently-available options — filtered by upstream selections, exactly what the user sees — plus the current selections and when the facet data was last refreshed from CADC. Long option lists are capped per column (`truncated: true`). Use the values with `set_search_constraints` / `set_search_form`.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await snapshot()
    }
}

// MARK: - refresh_data_train

/// Re-fetch the data-train facet data from CADC — the panel's refresh
/// button.
struct RefreshDataTrainTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Refreshed: Sendable {
        let error: String?
        let lastRefreshedISO: String?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let lastRefreshedISO: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "refresh_data_train",
        description: "Re-fetch the data-train facet data (bands/collections/instruments/…) from CADC — the \"Additional Constraints\" panel's refresh button. Blocks until the fetch completes. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let refresh: @Sendable () async -> Refreshed

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let result = await refresh()
        if let message = result.error {
            return .failed(.backendError(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(
                applied: true, lastRefreshedISO: result.lastRefreshedISO))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - set_adql_editor

/// Put text into the ADQL editor tab (or regenerate it from the form),
/// optionally executing it — without saving anything.
struct SetADQLEditorTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var adql: String?
        var generateFromForm: Bool?
        var execute: Bool?

        init() {}
        init(adql: String? = nil, generateFromForm: Bool? = nil, execute: Bool? = nil) {
            self.adql = adql
            self.generateFromForm = generateFromForm
            self.execute = execute
        }
    }

    struct Outcome: Sendable {
        var error: String? = nil
        var adql: String = ""
        var executed: Bool = false
        var resultCount: Int? = nil
        var searchError: String? = nil
        /// The person pressed Cancel while it ran.
        var cancelled: Bool = false
    }

    /// Also `execute_adql_query`'s reply.
    struct Output: Encodable, Sendable {
        let applied: Bool
        let adql: String
        let executed: Bool
        let resultCount: Int?
        let searchError: String?
        let cancelled: Bool

        init(_ outcome: Outcome) {
            applied = true
            adql = outcome.adql
            executed = outcome.executed
            resultCount = outcome.resultCount
            searchError = outcome.searchError
            cancelled = outcome.cancelled
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_adql_query",
        description: "Set the ADQL editor tab's text without saving anything: pass `adql` to set it directly, or `generateFromForm: true` to regenerate it from the current form (the editor's \"Generate from Form\" button) — not both. Pass `execute: true` to run the editor's (possibly new) content afterwards; with neither source given, `execute` runs the current editor text. Switches the Search view to the ADQL tab. Live-applied; no proposal. (Windows wire name; macOS also exposes `set_adql_editor` and `execute_adql_query` aliases.)",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "adql":             { "type": "string", "minLength": 1, "description": "Raw ADQL to place in the editor." },
            "generateFromForm": { "type": "boolean", "description": "Regenerate the editor text from the current form state." },
            "execute":          { "type": "boolean", "description": "Run the editor's content after applying." }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (Args) async -> Outcome

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if args.adql != nil && args.generateFromForm == true {
            return .failed(.invalidArgument("Pass `adql` or `generateFromForm`, not both"))
        }
        if args.adql == nil && args.generateFromForm != true && args.execute != true {
            return .failed(.invalidArgument("Nothing to do — pass `adql`, `generateFromForm`, or `execute`"))
        }
        let outcome = await apply(args)
        if let message = outcome.error {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(outcome))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - select_search_tab

/// Switch the Search view's sub-tab (Search form / Results / ADQL).
struct SelectSearchTabTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let tab: String
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "select_search_tab",
        description: "Switch the Search view's sub-tab: `search` (the constraint form), `results` (the results table), or `adql` (the raw-query editor). Also navigates the app to Search if it's elsewhere. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["tab"],
          "properties": {
            "tab": { "type": "string", "enum": ["search", "results", "adql"] }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Returns an error message on failure, or nil when applied.
    let select: @Sendable (String) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if let message = await select(args.tab) {
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

// MARK: - quick_search

/// One-click "narrow by this value" — the results table's quick-search
/// cell links. Overwrites just that form field and re-runs the search.
struct QuickSearchTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let columnID: String
        let value: String
    }

    struct Outcome: Sendable {
        var error: String? = nil
        var resultCount: Int? = nil
        var searchError: String? = nil
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let resultCount: Int?
        let searchError: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "quick_search",
        description: "The results table's one-click \"narrow by this value\" links, as a tool: overwrite a single quick-searchable form field (piname, proposalid, targetname, collection, or instrument) with `value` and re-run the search — leaving all other constraints in place so you drill into the current result set. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["columnID", "value"],
          "properties": {
            "columnID": { "type": "string", "enum": ["piname", "proposalid", "targetname", "collection", "instrument"] },
            "value":    { "type": "string", "minLength": 1 }
          },
          "additionalProperties": false
        }
        """#
    )

    let run: @Sendable (String, String) async -> Outcome

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        let outcome = await run(args.columnID, args.value)
        if let message = outcome.error {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(
                applied: true,
                resultCount: outcome.resultCount,
                searchError: outcome.searchError))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - rename_recent_search

/// Rename an entry in the Recent Searches panel.
struct RenameRecentSearchTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let id: String
        let name: String
    }

    struct Payload: Codable, Sendable {
        let id: String
        let name: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "rename_recent_search",
        description: "Rename a Recent Searches entry (by id from `list_recent_searches`) — the panel's inline rename. Persisted immediately when auto-apply is on; otherwise queues to the proposal strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["id", "name"],
          "properties": {
            "id":   { "type": "string", "description": "UUID string of the recent search." },
            "name": { "type": "string", "minLength": 1 }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard UUID(uuidString: args.id) != nil else {
            throw ToolFailureReason.invalidArgument("id is not a UUID")
        }
        let name = args.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw ToolFailureReason.invalidArgument("name is empty")
        }
        return try ProposalPlan.encoding(
            kind: "rename_recent_search",
            summary: "Rename recent search to '\(name)'",
            payload: Payload(id: args.id, name: name)
        )
    }
}

// MARK: - remove_recent_search (destructive)

struct RemoveRecentSearchTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Payload: Codable, Sendable {
        let id: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "remove_recent_search",
        description: "Remove one Recent Searches entry by id. Destructive — runs immediately when auto-apply is on; otherwise queues for explicit confirmation in the strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string", "description": "UUID string of the recent search." } },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard UUID(uuidString: args.id) != nil else {
            throw ToolFailureReason.invalidArgument("id is not a UUID")
        }
        return try ProposalPlan.encoding(
            kind: "remove_recent_search",
            summary: "Remove recent search \(args.id)",
            payload: Payload(id: args.id)
        )
    }
}

// MARK: - clear_recent_searches (destructive)

struct ClearRecentSearchesTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    typealias Args = EmptyArgs

    struct Payload: Codable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "clear_recent_searches",
        description: "Remove ALL Recent Searches entries — the panel's Clear All. Destructive — runs immediately when auto-apply is on; otherwise queues for explicit confirmation in the strip.",
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
            kind: "clear_recent_searches",
            summary: "Clear all recent searches",
            payload: Payload()
        )
    }
}

// MARK: - Appliers

/// Runs when the user clicks Apply on a `rename_recent_search` proposal
/// (or immediately when auto-apply is on).
struct RenameRecentSearchApplier: ProposalApplier {
    let kind = "rename_recent_search"
    let store: RecentSearchStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(RenameRecentSearchTool.Payload.self, from: proposal.payload)
        guard let id = UUID(uuidString: payload.id) else {
            throw ProposalApplyError.backendError("invalid id")
        }
        try await MainActor.run {
            guard let existing = store.searches.first(where: { $0.id == id }) else {
                throw ProposalApplyError.backendError("recent search not found: \(id)")
            }
            store.rename(existing, to: payload.name)
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

struct RemoveRecentSearchApplier: ProposalApplier {
    let kind = "remove_recent_search"
    let store: RecentSearchStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(RemoveRecentSearchTool.Payload.self, from: proposal.payload)
        guard let id = UUID(uuidString: payload.id) else {
            throw ProposalApplyError.backendError("invalid id")
        }
        try await MainActor.run {
            guard let existing = store.searches.first(where: { $0.id == id }) else {
                throw ProposalApplyError.backendError("recent search not found: \(id)")
            }
            store.remove(existing)
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

struct ClearRecentSearchesApplier: ProposalApplier {
    let kind = "clear_recent_searches"
    let store: RecentSearchStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        await MainActor.run {
            store.clear()
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}
