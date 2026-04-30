// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// New for the 2026-04-30 astronomer workflow review.

import Foundation
import VerbinalKit

/// Return what the user is currently looking at in the app.
///
/// Lets agents reason in context: "I see you're in Search — want me
/// to find more like that?", "You're in the FITS viewer with epoch
/// 729989 open; I'll keep my next reads scoped to it." Without this,
/// every tool call is stateless from the agent's perspective.
///
/// Bodies / payloads are not exposed — only navigation state and
/// what's actively in view. Read-only; no auth required.
struct GetCurrentViewTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        /// One of: "landing", "search", "research", "portal", "storage", "fitsViewer".
        let mode: String
        /// Human-readable: "FITS Viewer", "Search", "Research", etc.
        let modeTitle: String
        let isAuthenticated: Bool
        let username: String

        // ── Per-mode optional context ─────────────────────────────

        /// (Search) The form's current sky position, if set. Reflects
        /// any `set_search_focus` an agent has applied.
        let searchFocusRA: Double?
        let searchFocusDec: Double?

        /// (FITS Viewer) Local paths of all FITS files currently open
        /// in viewer tabs. Empty when the empty-state placeholder is
        /// showing.
        let openFITSPaths: [String]

        // ── Cross-mode signals ───────────────────────────────────

        /// Live count of pending agent proposals in the strip — useful
        /// so an agent doesn't fire writes that will instantly trip
        /// the per-turn cap.
        let pendingProposalsCount: Int
        /// True when the user has enabled the MCP listener.
        let agentsEnabled: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_current_view",
        description: "Return what the user is currently looking at: which mode (landing/search/research/portal/storage/fitsViewer), auth state, search-form focus when in Search, open FITS files when in FITS Viewer, plus pending-proposal count so you can pace writes.",
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
