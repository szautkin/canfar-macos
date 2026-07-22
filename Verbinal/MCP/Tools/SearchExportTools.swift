// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - export_search_results

/// Export search results to a file in the user's Downloads folder.
/// Either re-runs the current results or a caller-supplied ADQL query.
struct ExportSearchResultsTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let format: String
        var adql: String?
        var maxRecords: Int?
    }

    struct Payload: Codable, Sendable {
        let format: String
        let adql: String?
        let maxRecords: Int?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "export_search_results",
        description: "Export search results as a file in the user's Downloads folder. Omit `adql` to export the current search results; pass `adql` to run a custom query and export that instead. `maxRecords` caps the row count. Runs immediately when auto-apply is on; otherwise queues to the proposal strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["format"],
          "properties": {
            "format":     { "type": "string", "enum": ["csv", "tsv", "votable"], "description": "Output file format." },
            "adql":       { "type": "string", "description": "Optional custom ADQL to run instead of exporting the current results." },
            "maxRecords": { "type": "integer", "minimum": 1, "description": "Optional cap on the number of exported rows." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let allowedFormats: Set<String> = ["csv", "tsv", "votable"]
        guard allowedFormats.contains(args.format) else {
            throw ToolFailureReason.invalidArgument("format must be one of: csv, tsv, votable")
        }
        if let adql = args.adql {
            guard !adql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolFailureReason.invalidArgument("adql is empty — omit it to export the current results")
            }
        }
        if let maxRecords = args.maxRecords, maxRecords < 1 {
            throw ToolFailureReason.invalidArgument("maxRecords must be >= 1")
        }
        var summary = "Export search results as \(args.format.uppercased()) to Downloads"
        if args.adql != nil {
            summary += " (custom ADQL)"
        }
        return try ProposalPlan.encoding(
            kind: "export_search_results",
            summary: summary,
            payload: Payload(
                format: args.format,
                adql: args.adql,
                maxRecords: args.maxRecords
            )
        )
    }
}

/// Concrete handler that runs when the user clicks Apply on an
/// `export_search_results` proposal (or immediately under auto-apply).
struct ExportSearchResultsApplier: ProposalApplier {
    let kind = "export_search_results"

    /// Returns the path of the written file; the closure owns logging.
    let run: @Sendable (_ format: String, _ adql: String?, _ maxRecords: Int?) async throws -> String
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(ExportSearchResultsTool.Payload.self, from: proposal.payload)
        do {
            _ = try await run(payload.format, payload.adql, payload.maxRecords)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("export failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}

// MARK: - load_saved_search

/// Load a saved ADQL query or a recent search back into the Search UI —
/// the same thing the user's 'Load' buttons do, as a tool. Live-applied
/// view state; no proposal.
struct LoadSavedSearchTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var savedQueryID: String?
        var recentSearchID: String?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let target: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "load_saved_search",
        description: "Load a saved ADQL query into the ADQL editor (`savedQueryID`), or a recent search's form snapshot into the Search form (`recentSearchID`), and navigate to Search — the UI 'Load' buttons as a tool. Provide exactly one of the two ids. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "savedQueryID":   { "type": "string", "description": "UUID of a saved query (from list_saved_queries). Loads its ADQL into the editor." },
            "recentSearchID": { "type": "string", "description": "UUID of a recent search (from list_recent_searches). Loads its form snapshot into the Search form." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Applies the load and navigates. Returns an error message on
    /// failure (e.g. unknown id), or nil on success.
    let apply: @Sendable (String?, String?) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        switch (args.savedQueryID, args.recentSearchID) {
        case (nil, nil):
            return .failed(.invalidArgument("provide exactly one of savedQueryID or recentSearchID (neither was set)"))
        case (.some, .some):
            return .failed(.invalidArgument("provide exactly one of savedQueryID or recentSearchID (both were set)"))
        default:
            break
        }
        if let message = await apply(args.savedQueryID, args.recentSearchID) {
            return .failed(.backendError(message))
        }
        let target: String
        if let savedQueryID = args.savedQueryID {
            target = "saved_query \(savedQueryID)"
        } else {
            target = "recent_search \(args.recentSearchID ?? "")"
        }
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true, target: target))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
