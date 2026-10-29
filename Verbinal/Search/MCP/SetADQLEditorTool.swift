// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

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
        /// With `execute`, false: answer at once that it has started.
        var wait: Bool?

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
        /// Run without waiting (`wait: false`): it has started, and goes on.
        var started: Bool = false
        /// The query's publisher ID: added, there already, or why not (plan 54 D2).
        var identifier: IdentifierReport? = nil
    }

    /// Also `execute_adql_query`'s reply.
    struct Output: Encodable, Sendable {
        let applied: Bool
        let adql: String
        let executed: Bool
        let resultCount: Int?
        let searchError: String?
        let cancelled: Bool
        /// It runs on; `cancel_search` stops it (plan 30 R2).
        let started: Bool
        let identifier: IdentifierReport?

        init(_ outcome: Outcome) {
            applied = true
            adql = outcome.adql
            identifier = outcome.identifier
            executed = outcome.executed
            resultCount = outcome.resultCount
            searchError = outcome.searchError
            cancelled = outcome.cancelled
            started = outcome.started
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_adql_query",
        description: "Set the ADQL editor tab's text without saving anything: pass `adql` to set it directly, or `generateFromForm: true` to regenerate it from the current form (the editor's \"Generate from Form\" button) — not both. Pass `execute: true` to run the editor's (possibly new) content afterwards; with neither source given, `execute` runs the current editor text; a query the checker is sure CADC would refuse is not sent — `executed: false`, the reason in `searchError`. A query of products runs with its publisher ID: when it does not select one, `Plane.publisherID AS \"Publisher ID\"` is added, the editor shows the query as run (`adql`), and `identifier.added` says so; `identifier.note` says why a query's rows have none (DISTINCT, GROUP BY, aggregates, caom2.Observation alone), with the JOIN that gives them one. Switches the Search view to the ADQL tab. Live-applied; no proposal. (Windows wire name; macOS also exposes `set_adql_editor` and `execute_adql_query` aliases.)",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "adql":             { "type": "string", "description": "Raw ADQL to place in the editor; \"\" clears it." },
            "generateFromForm": { "type": "boolean", "description": "Regenerate the editor text from the current form state." },
            "execute":          { "type": "boolean", "description": "Run the editor's content after applying." },
            "wait":             { "type": "boolean", "description": "With `execute`: false answers at once that it has started (`started: true`) — get_search_results then says `state: searching` until its results are there; cancel_search stops it. Default true: the answer waits for the results." }
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
