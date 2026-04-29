// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Type-level classification of what a tool *does*.
///
/// `VerbClass` is declared **statically** on each `AITool` conformance so
/// the router can read it without instantiating the tool. The class drives
/// three downstream gates:
///
///   1. Origin × class permission matrix (what an external agent is
///      allowed to call vs. what only the in-app user can invoke).
///   2. Whether the call is wrapped in a proposal (writes) or applied
///      live (view-state).
///   3. Audit-log bucketing.
public enum VerbClass: String, Codable, Sendable, Equatable {
    /// Read-only. Returns data; never mutates state. Always permitted to
    /// external agents (subject to higher-level approval gating).
    case read

    /// Authorial mutation: titles, bodies, links, observations metadata,
    /// notes. Requires a proposal that the user accepts.
    case semanticWrite

    /// Permanent removal — deletion of files, records, sessions, etc.
    /// Requires a proposal **and** a two-step confirmation in the strip
    /// UI to defend against agent or user slip.
    case destructive

    /// Cosmetic UI state — sort order, current selection, theme, layout.
    /// Live-applied; does not consume proposal budget.
    case viewState

    /// Lifecycle operations on the proposal queue itself: list, get
    /// state, withdraw. Bypass the proposal gate (the queue is the
    /// thing being managed).
    case proposalLifecycle

    /// Undo / redo. Reaches into the application's command history.
    case undo
}
