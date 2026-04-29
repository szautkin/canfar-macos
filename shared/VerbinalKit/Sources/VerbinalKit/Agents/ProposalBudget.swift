// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Per-origin proposal cap. Defends against runaway agent loops that
/// would otherwise pile dozens of pending items into the user's strip
/// before they can react.
///
/// The router consults the budget *after* a tool returns `.proposed` so
/// the proposal has already been enqueued at that point. If the budget
/// is exceeded we ask the store to `withdraw` the proposal — no partial
/// batch ever lands visibly.
///
/// Reset semantics: per-turn (chat) and per-session (external) callers
/// reset their counts at well-defined boundaries:
///   * chat: end of turn
///   * external: MCP session disconnect
///   * user: never (the user sees the strip; that's the natural cap)
public actor ProposalBudget {
    public nonisolated let limit: Int
    private var counts: [OperationOrigin: Int] = [:]

    public init(limit: Int = 8) {
        precondition(limit > 0, "ProposalBudget limit must be positive")
        self.limit = limit
    }

    /// Reserve a slot. Returns `true` on success, `false` when the
    /// origin's per-turn cap would be exceeded. The caller is expected
    /// to withdraw the proposal it just enqueued on `false`.
    public func tryAccept(origin: OperationOrigin) -> Bool {
        let current = counts[origin, default: 0]
        guard current < limit else { return false }
        counts[origin] = current + 1
        return true
    }

    /// Snapshot of remaining budget for an origin; surfaces in MCP
    /// responses so agents can self-throttle.
    public func remaining(for origin: OperationOrigin) -> Int {
        max(0, limit - counts[origin, default: 0])
    }

    /// Reset on turn / session boundary. The caller is expected to know
    /// when those boundaries fire (e.g. external resets when the MCP
    /// session disconnects).
    public func reset(origin: OperationOrigin) {
        counts.removeValue(forKey: origin)
    }

    /// Reset everything (test helper, app shutdown).
    public func resetAll() {
        counts.removeAll()
    }
}
