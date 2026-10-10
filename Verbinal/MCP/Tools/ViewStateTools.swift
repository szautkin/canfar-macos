// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// View-state tools — live-applied, no proposal. Verb class is
/// `.viewState`, so the router doesn't budget-gate them. These are
/// "do something on the user's UI" rather than "change persistent
/// state"; the user sees the effect immediately and can undo by
/// navigating.

// MARK: - set_search_focus

/// Pre-position the search form on a sky coordinate. The next time the
/// user navigates to Search, the form's RA/Dec inputs are pre-filled.
/// Live-applied.
struct SetSearchFocusTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let raDeg: Double
        let decDeg: Double
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let raDeg: Double
        let decDeg: Double
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_search_focus",
        description: "Pre-position the search form on (RA, Dec) in degrees. Live-applied; visible the next time the user opens Search. Does NOT auto-navigate — chain `navigate_to(mode: \"search\")` after this if you want the user to see it immediately. Existing radius/collection filters in the form are preserved.",
        schema: #"""
        {
          "type": "object",
          "required": ["raDeg", "decDeg"],
          "properties": {
            "raDeg":  { "type": "number", "minimum": 0,    "exclusiveMaximum": 360 },
            "decDeg": { "type": "number", "minimum": -90,  "maximum": 90 }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (_ ra: Double, _ dec: Double) async -> Void

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        await apply(args.raDeg, args.decDeg)
        do {
            let body = Output(applied: true, raDeg: args.raDeg, decDeg: args.decDeg)
            let bytes = try JSONEncoder().encode(body)
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
