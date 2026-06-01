// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Side-effect events the agent surface needs to observe — most often
/// the resolution of proposals it submitted.
///
/// Pattern adopted from verbinal-thought ADR-0037: the v1 delivery is a
/// polling tool (`list_events`) with monotonic tokens; agents read since
/// the highest token they've seen and update their token from the
/// response. A future MCP-resource implementation can layer push
/// notifications on top of this enum without changing the wire shape.
public enum AgentEvent: Sendable, Equatable {
    /// A proposal arrived in the user's strip. Carries the proposal id
    /// + kind so the agent can correlate against its own submission.
    case proposalArrived(id: UUID, kind: String, originKind: String)
    case proposalApplied(id: UUID, kind: String)
    case proposalRejected(id: UUID, kind: String)
    case proposalWithdrawn(id: UUID, kind: String)
}

/// One record in the event log.
///
/// `token` is monotonic and dense: the next entry always has a strictly
/// greater token than its predecessor. Encoded as a string on the wire
/// to dodge JSON-number-precision concerns; agents pass the highest
/// token they've seen back in `since_token` to read only what's new.
public struct AgentEventEntry: Sendable, Equatable {
    public let token: UInt64
    public let occurredAt: Date
    public let event: AgentEvent

    public init(token: UInt64, occurredAt: Date, event: AgentEvent) {
        self.token = token
        self.occurredAt = occurredAt
        self.event = event
    }
}

/// Append-only bounded buffer. Old entries fall out the back when the
/// buffer fills, so the log self-trims — no manual GC, no migrations.
/// Agents that poll faster than the drop rate see every event; agents
/// that fall behind get an "expired token" hint and re-baseline.
///
/// Default capacity 500 — at ~4 lifecycle events per proposal, that
/// holds ~125 proposals' worth of history.
public actor EventLog {

    public let capacity: Int
    private var buffer: [AgentEventEntry] = []
    private var nextToken: UInt64 = 1

    public init(capacity: Int = 500) {
        precondition(capacity > 0, "EventLog capacity must be positive")
        self.capacity = capacity
        buffer.reserveCapacity(capacity)
    }

    /// Append a single event. Returns the assigned token.
    @discardableResult
    public func append(_ event: AgentEvent, at date: Date = Date()) -> UInt64 {
        let token = nextToken
        nextToken &+= 1
        let entry = AgentEventEntry(token: token, occurredAt: date, event: event)
        buffer.append(entry)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        return token
    }

    /// Read entries with token strictly greater than `since`. Returns
    /// `(entries, expired)` where `expired = true` if the caller's
    /// `since` predates the buffer's earliest retained entry — the
    /// caller must re-baseline.
    public func entries(since: UInt64) -> (entries: [AgentEventEntry], expired: Bool) {
        guard let earliest = buffer.first?.token else { return ([], false) }
        // Expired when the caller's cursor sits more than one token behind
        // the earliest retained entry (a gap = entries were dropped).
        // Written as `earliest - since > 1` under an `earliest > since`
        // guard so there's no UInt64 underflow (vs. the old `earliest - 1`).
        let expired = since > 0 && earliest > since && earliest - since > 1
        let cut = buffer.filter { $0.token > since }
        return (cut, expired)
    }

    /// Snapshot the most-recent token without reading entries.
    public func currentToken() -> UInt64 {
        buffer.last?.token ?? 0
    }

    /// Test helper.
    public func snapshot() -> [AgentEventEntry] { buffer }
}
