// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - export_search_results

/// Export search results to a file in the user's Downloads folder, their
/// storage, or both. Either re-runs the current results or a
/// caller-supplied ADQL query.
struct ExportSearchResultsTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let format: String
        var adql: String?
        var maxRecords: Int?
        var uploadToVOSpace: Bool?
        var vospacePath: String?
        var keepLocal: Bool?
    }

    struct Payload: Codable, Sendable {
        let format: String
        let adql: String?
        let maxRecords: Int?
        /// To the person's storage too (plan 36 2.11), at `vospacePath`
        /// (Verbinal-Exports/ when none); `keepLocal` false: only there.
        var uploadToVOSpace: Bool? = nil
        var vospacePath: String? = nil
        var keepLocal: Bool? = nil

        var goesToStorage: Bool { uploadToVOSpace == true }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "export_search_results",
        description: "Export search results as a file in the user's Downloads folder, or in their CANFAR storage: `uploadToVOSpace` puts it there too, at `vospacePath` (a folder, or a path ending in the file's extension; default Verbinal-Exports/), and `keepLocal: false` keeps it only there. Omit `adql` to export the current search results — as CSV or TSV, only the columns shown in the results table, in their order (set_results_view shows or hides them); as VOTable, every column of the query; pass `adql` to run a custom query and export every column it returns. `maxRecords` caps the row count. The answer gives the file, where it went in storage, and its rows and columns.",
        schema: #"""
        {
          "type": "object",
          "required": ["format"],
          "properties": {
            "format":     { "type": "string", "enum": ["csv", "tsv", "votable"], "description": "Output file format." },
            "adql":       { "type": "string", "description": "Optional custom ADQL to run instead of exporting the current results." },
            "maxRecords": { "type": "integer", "minimum": 1, "description": "Optional cap on the number of exported rows." },
            "uploadToVOSpace": { "type": "boolean", "description": "Put the file in the person's storage too. Default false; true when vospacePath is given." },
            "vospacePath": { "type": "string", "description": "Where in storage: a folder, or a path ending in .csv, .tsv or .xml. Default Verbinal-Exports/." },
            "keepLocal": { "type": "boolean", "description": "Keep the copy in Downloads (default true); false keeps the file only in storage." }
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
        if args.vospacePath != nil, args.uploadToVOSpace == false {
            throw ToolFailureReason.invalidArgument("vospacePath goes with uploadToVOSpace — leave it out, or set uploadToVOSpace true")
        }
        let toStorage = args.uploadToVOSpace ?? (args.vospacePath != nil)
        if args.keepLocal == false, !toStorage {
            throw ToolFailureReason.invalidArgument("keepLocal false needs uploadToVOSpace — the file would be kept nowhere")
        }
        let place = args.vospacePath ?? "\(ResultUpload.defaultFolder)/"
        var summary = "Export search results as \(args.format.uppercased())"
        switch (toStorage, args.keepLocal ?? true) {
        case (false, _): summary += " to Downloads"
        case (true, true): summary += " to Downloads and storage (\(place))"
        case (true, false): summary += " to storage (\(place))"
        }
        if args.adql != nil {
            summary += " (custom ADQL)"
        }
        return try ProposalPlan.encoding(
            kind: "export_search_results",
            summary: summary,
            payload: Payload(
                format: args.format,
                adql: args.adql,
                maxRecords: args.maxRecords,
                uploadToVOSpace: toStorage ? true : nil,
                vospacePath: toStorage ? args.vospacePath : nil,
                keepLocal: args.keepLocal
            )
        )
    }
}

/// What an export wrote: the file, and its rows and columns when the app
/// wrote it from the table (plan 30 N5).
struct SearchExport: Sendable, Equatable {
    /// The file on this Mac; nil when it is kept only in storage.
    var path: String?
    /// "120 rows × 8 columns: the columns shown in the results table";
    /// nil for a file CADC wrote, with every column of its query.
    let shape: String?
    /// Where it went in the person's storage, from their home.
    var storagePath: String? = nil

    /// What the answer says beside the file.
    var note: String? {
        let parts = [shape, storagePath.map { "In storage at \($0)." }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    /// The shape of the table's own export: only the columns shown.
    static func shown(rows: Int, columns: Int) -> String {
        "\(rows) rows × \(columns) columns: the columns shown in the results table — set_results_view shows or hides them"
    }
}

/// Concrete handler that runs when the user clicks Apply on an
/// `export_search_results` proposal (or immediately under auto-apply).
struct ExportSearchResultsApplier: ResultReportingApplier {
    let kind = "export_search_results"

    /// Writes the file; the closure owns logging.
    let run: @Sendable (_ request: ExportSearchResultsTool.Payload) async throws -> SearchExport
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(ExportSearchResultsTool.Payload.self, from: proposal.payload)
        let export: SearchExport
        do {
            export = try await run(payload)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("export failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        return (try? JSONEncoder().encode(AutoAppliedAck.Extra(note: export.note, file: export.path ?? export.storagePath))) ?? Data()
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
