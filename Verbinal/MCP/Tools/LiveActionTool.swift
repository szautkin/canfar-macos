// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// A live UI action for an agent — a click, not a proposal: decode the
/// arguments, perform, and answer `{ "applied": true }` or the reason it
/// could not. One implementation instead of the same forty lines per tool.
struct LiveActionTool<Args: Decodable & Sendable>: AITool {
    static var verbClass: VerbClass { .viewState }
    static var agentSafe: Bool { true }

    struct Output: Encodable, Sendable {
        let applied: Bool
    }

    let definition: AIToolDefinition
    /// Returns why the action could not be done, or nil when it was.
    let perform: @Sendable (Args) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            let object = arguments.isEmpty || String(decoding: arguments, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "null" ? Data("{}".utf8) : arguments
            args = try JSONDecoder().decode(Args.self, from: object)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if let reason = await perform(args) {
            return .failed(.invalidArgument(reason))
        }
        do {
            return .data(try JSONEncoder().encode(Output(applied: true)))
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - Tabs and observation detail

enum ViewerTabActions {
    struct CloseArgs: Decodable, Sendable {
        let kind: String
        var index: Int?
    }

    static func closeTab(perform: @escaping @Sendable (CloseArgs) async -> String?) -> LiveActionTool<CloseArgs> {
        LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "close_tab",
                description: "Close a viewer tab. `kind`: fits or cube. `index` is the 0-based position list_open_tabs reports; omit it to close the active tab. Closing shifts the indices of later tabs, so close from the highest index down when closing several. The Cube Viewer always keeps one tab. Live-applied; no proposal.",
                schema: #"""
                {
                  "type": "object",
                  "required": ["kind"],
                  "properties": {
                    "kind": { "type": "string", "enum": ["fits", "cube"] },
                    "index": { "type": "integer", "minimum": 0 }
                  },
                  "additionalProperties": false
                }
                """#),
            perform: perform)
    }
}
