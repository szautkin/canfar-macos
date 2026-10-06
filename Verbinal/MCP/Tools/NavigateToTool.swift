// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Steer the user's window to a specific app section so they actually
/// see what the agent is talking about.
///
/// Live-applied like `open_fits_file` — no proposal, returns
/// immediately. The agent calls this *deliberately* to guide the user
/// ("I've prepared the saved query, switching you to Search now").
/// Distinct from the implicit follow-on navigation that fires after
/// auto-applied writes when the user has "Follow agent activity"
/// enabled — that one is a passive safety net; this one is the
/// agent's own steering wheel.
struct NavigateToTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        /// One of: "landing", "search", "research", "portal",
        /// "storage", "fitsViewer". Same set the rest of the surface
        /// uses (matches `get_current_view.mode`).
        let mode: String
    }

    struct Output: Encodable, Sendable {
        let navigated: Bool
        let mode: String
        let modeTitle: String
        /// False when no Verbinal window shows: the screen changed where the
        /// person cannot see it (plan 30 N4). Absent when one shows.
        var showing: Bool?
        var note: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "navigate_to",
        description: "Switch the user's window to a specific app section: landing (dashboard / home), search (CADC archive search form), research (downloaded observations + notes), portal (sessions dashboard), storage (VOSpace browser), fitsViewer (the FITS viewer; open a file via `open_fits_file` first), cubeViewer (the 3D spectral-cube viewer; open a cube via `open_cube` first), aiGuide, workflows, remoteCompute (the Remote Compute screen: the compute session, its runs, and a box to run code; needs sign-in). Live-applied; use deliberately to keep the user oriented.",
        schema: #"""
        {
          "type": "object",
          "required": ["mode"],
          "properties": {
            "mode": {
              "type": "string",
              "enum": ["landing", "search", "research", "portal", "storage", "fitsViewer", "cubeViewer", "aiGuide", "workflows", "remoteCompute"]
            }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Navigates; answers why the person cannot see it, nil when they can.
    let navigate: @Sendable (_ mode: AppMode) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        guard let mode = Self.mode(from: args.mode) else {
            return .failed(.invalidArgument("unknown mode '\(args.mode)'"))
        }
        let unseen = await navigate(mode)
        let body = Output(
            navigated: true,
            mode: args.mode,
            modeTitle: Self.title(for: mode),
            showing: unseen == nil ? nil : false,
            note: unseen
        )
        do {
            let bytes = try JSONEncoder().encode(body)
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }

    private static func mode(from key: String) -> AppMode? { AppMode(key: key) }

    private static func title(for mode: AppMode) -> String { mode.title }
}
