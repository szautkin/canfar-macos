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
        /// The person's standing rules — their guide tools — so an agent
        /// that only looks here still meets them; the tool's description
        /// names them first.
        /// What the person allows without asking, kind by kind (plan 30 A):
        /// `allowed` applies at once, the rest waits in Pending. Re-read it; the
        /// person can change it between turns.
        var permissions: [ChangeCatalog.Permission] = []
        var standingRules: [AIGuideSnapshot.StandingRule] = []
        /// (Search) The observation whose detail sheet is open.
        var openSearchDetail: Record? = nil
        /// (Research) The record selected in the list, its detail shown.
        var selectedResearchRecord: Record? = nil
        /// The screen as list_ui_targets names it: `search.results`, `portal`.
        var screen: String? = nil
        /// The hints up now, by set (show_ui_hints, point_at_ui).
        var hints: [HintSet] = []

        struct HintSet: Encodable, Sendable, Equatable {
            let set: String
            let hints: [String]
        }

        /// An observation the screen is showing: its row or record id and its plane.
        struct Record: Encodable, Sendable, Equatable {
            let id: String
            let publisherID: String
            let observationID: String
        }
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

        /// (Search) The selected sub-tab: "search", "results", or "adql".
        let searchTab: String?
        /// (Search) Loaded results-table row count, and how many survive
        /// the user's live per-column filters. Nil when no results are
        /// loaded. Read the table itself with `get_search_results`.
        let searchResultsTotal: Int?
        let searchResultsFiltered: Int?

        /// (FITS Viewer) Local paths of all FITS files currently open
        /// in viewer tabs. Empty when the empty-state placeholder is
        /// showing.
        let openFITSPaths: [String]

        /// Set when the "Open as…" sheet is showing for an NAXIS≥3
        /// file. Call `choose_viewer` before FITS/cube steering tools —
        /// nothing is open in either viewer until the user (or you)
        /// picks 2D vs 3D.
        let pendingViewerChoice: PendingViewerChoice?

        struct PendingViewerChoice: Encodable, Sendable {
            let path: String
            let filename: String
            let note: String
        }

        // ── Cross-mode signals ───────────────────────────────────

        /// Live count of pending agent proposals in the strip — useful
        /// so an agent doesn't fire writes that will instantly trip
        /// the per-turn cap. In auto-apply mode this is normally zero
        /// (auto-applied writes never queue); a non-zero value means
        /// either the user has toggled auto-apply off or some prior
        /// auto-apply failed and left a residual.
        let pendingProposalsCount: Int
        /// True when the user has enabled the MCP listener.
        let agentsEnabled: Bool
        /// True when write proposals auto-apply (default). False when
        /// the user has switched to strip-confirm mode — your writes
        /// will queue and wait for an Apply click. Re-read this if
        /// you've been running for a while; the user can flip it
        /// between turns.
        let autoApplyEnabled: Bool
        /// True when the app navigates the user to the relevant view
        /// after each auto-applied write (saved-query → Search,
        /// observation/note → Research, VOSpace → Storage, session →
        /// Portal). When this is on you don't need a redundant
        /// `navigate_to` call after a write — the app already
        /// followed. When off, the user stays put after writes;
        /// `navigate_to` is your only way to keep them oriented.
        let followAgentActivityEnabled: Bool
        /// Proposal-budget window for the current MCP turn. `cap` is
        /// the static per-turn ceiling (default 8); `remaining` is
        /// how many more proposals you can submit before hitting
        /// `perTurnProposalCapExceeded`. Reset at the start of each
        /// turn. Read this when pacing a batch of writes so you
        /// don't get refused mid-sequence — added in response to
        /// the 2026-05-14 QA review that flagged "no way to ask
        /// how many proposals are left mid-turn".
        ///
        /// Defaults to zero-cap / zero-remaining so call sites
        /// that don't have a live `AIToolContext` (the snapshot
        /// closure produces the rest of the Output, then `handle`
        /// patches this field with the real budget). `var` so
        /// `handle` can mutate in place without rebuilding the
        /// whole struct.
        var proposalBudget: BudgetSnapshot = .init(cap: 0, remaining: 0)

        struct BudgetSnapshot: Encodable, Sendable {
            let cap: Int
            let remaining: Int
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_current_view",
        description: "Return the person's standing rules (`standingRules`: their guide tools — call each for its whole text and follow it), then what the user is currently looking at — including the observation whose Search detail is open (`openSearchDetail`) and the Research record selected (`selectedResearchRecord`): which mode (landing/search/research/portal/storage/fitsViewer/cubeViewer/aiGuide), auth state, the Search sub-tab and loaded-results counts, search-form focus when set, open FITS files when in FITS Viewer, `pendingViewerChoice` when the Open as… (2D FITS vs 3D Cube) sheet is showing — call `choose_viewer` to dismiss it — pending-proposal count, `permissions` (what the person allows without asking, kind by kind: an `allowed` kind applies at once, the rest waits in Pending; `autoApplyEnabled` is true while any kind is allowed) and `followAgentActivityEnabled` (does the app auto-navigate to the relevant view after a write, so you don't need a redundant `navigate_to`?).",
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
        var out = await snapshot()
        // Fill in the live proposal budget from the context. The
        // snapshot closure doesn't have access to it (it's
        // produced once at tool-registration time before any
        // request arrives); reading at handle-time is the only
        // place we can see the *caller's* origin and the per-
        // origin counter inside the ProposalBudget actor.
        let cap = context.budget.limit
        let remaining = await context.budget.remaining(for: context.origin)
        out.proposalBudget = .init(cap: cap, remaining: remaining)
        return out
    }
}
