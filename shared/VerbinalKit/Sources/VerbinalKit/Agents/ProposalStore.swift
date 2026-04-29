// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Capability the bridge passes into tools so they can enqueue proposals
/// without coupling to a concrete store.
public protocol ProposalStore: Sendable {
    /// Enqueue a proposal and return it (so callers see the assigned id).
    func enqueue(_ proposal: PendingProposal) async -> PendingProposal

    /// All proposals, optionally filtered by origin.
    func list(origin: OperationOrigin?) async -> [PendingProposal]

    /// Look up a proposal by id; returns its lifecycle state.
    func state(_ id: UUID) async -> ProposalState

    /// Mark applied (called by the strip UI after the applier succeeds).
    @discardableResult
    func markApplied(_ id: UUID) async -> Bool

    /// Mark rejected (the user clicked Reject in the strip).
    @discardableResult
    func markRejected(_ id: UUID) async -> Bool

    /// Withdraw — the *agent* retracted its own pending proposal. Same
    /// effect as reject but a different audit category.
    @discardableResult
    func withdraw(_ id: UUID) async -> Bool
}

/// In-memory implementation. Keeps a small ring of tombstones so
/// `state(_:)` can answer "applied" or "rejected" for a short window
/// after the proposal leaves the live queue (matches the ~5 min window
/// VT documented for `get_proposal_state`).
public actor InMemoryProposalStore: ProposalStore {
    private var pending: [UUID: PendingProposal] = [:]
    private var pendingOrder: [UUID] = []
    private var tombstones: [(UUID, ProposalState, Date)] = []
    /// How long resolved tombstones stay queryable. 5 minutes is what VT
    /// found agents needed for `get_proposal_state` round-trips.
    public let tombstoneTTL: TimeInterval = 5 * 60
    /// Hard cap on tombstone count even if TTL has not elapsed; defends
    /// against memory growth in long-lived sessions.
    public let tombstoneCap: Int = 256

    public init() {}

    public func enqueue(_ proposal: PendingProposal) -> PendingProposal {
        pending[proposal.id] = proposal
        pendingOrder.append(proposal.id)
        return proposal
    }

    public func list(origin: OperationOrigin? = nil) -> [PendingProposal] {
        let all = pendingOrder.compactMap { pending[$0] }
        guard let origin else { return all }
        return all.filter { $0.origin == origin }
    }

    public func state(_ id: UUID) -> ProposalState {
        gcTombstones()
        if pending[id] != nil { return .pending }
        if let hit = tombstones.first(where: { $0.0 == id }) { return hit.1 }
        return .unknown
    }

    @discardableResult
    public func markApplied(_ id: UUID) -> Bool { resolve(id, as: .applied) }

    @discardableResult
    public func markRejected(_ id: UUID) -> Bool { resolve(id, as: .rejected) }

    @discardableResult
    public func withdraw(_ id: UUID) -> Bool { resolve(id, as: .withdrawn) }

    // MARK: - Internals

    private func resolve(_ id: UUID, as state: ProposalState) -> Bool {
        guard pending.removeValue(forKey: id) != nil else { return false }
        if let i = pendingOrder.firstIndex(of: id) {
            pendingOrder.remove(at: i)
        }
        tombstones.append((id, state, Date()))
        if tombstones.count > tombstoneCap {
            tombstones.removeFirst(tombstones.count - tombstoneCap)
        }
        return true
    }

    private func gcTombstones() {
        let cutoff = Date().addingTimeInterval(-tombstoneTTL)
        tombstones.removeAll { $0.2 < cutoff }
    }
}
