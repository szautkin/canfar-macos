// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// On-disk snapshot of the proposal queue so pending items (and recent
/// resolutions) survive an app restart under their original ids.
public struct ProposalJournal: Codable, Sendable, Equatable {
    public var pending: [PendingProposal]
    public var tombstones: [Tombstone]
    /// Ids still in `pending` whose last apply threw. Cleared on a
    /// successful apply / reject / withdraw.
    public var failedIDs: [UUID]
    /// Why each of `failedIDs` failed, by id (plan 17 A4); absent in
    /// journals written before it was kept.
    public var failureReasons: [String: String]?

    public struct Tombstone: Codable, Sendable, Equatable {
        public var id: UUID
        public var state: ProposalState
        public var resolvedAt: Date
    }

    public init(
        pending: [PendingProposal] = [],
        tombstones: [Tombstone] = [],
        failedIDs: [UUID] = [],
        failureReasons: [String: String]? = nil
    ) {
        self.pending = pending
        self.tombstones = tombstones
        self.failedIDs = failedIDs
        self.failureReasons = failureReasons
    }
}

/// Capability the bridge passes into tools so they can enqueue proposals
/// without coupling to a concrete store.
///
/// Concurrency note: every requirement is declared `async` so the
/// protocol is honest about its cross-isolation contract — callers must
/// always `await`. A concrete actor conformer (see `InMemoryProposalStore`)
/// may satisfy a synchronous-looking `async` requirement with a method
/// written *without* the `async` keyword: actor isolation already makes
/// the cross-actor call suspend, so the keyword is implied at the call
/// site. The two declarations are not in conflict; the actor's bare
/// signature and the protocol's `async` signature describe the same
/// awaited call from outside the actor.
public protocol ProposalStore: Sendable {
    /// Enqueue a proposal and return it (so callers see the assigned id).
    func enqueue(_ proposal: PendingProposal) async -> PendingProposal

    /// All proposals, optionally filtered by origin.
    func list(origin: OperationOrigin?) async -> [PendingProposal]

    /// Look up a proposal by id; returns its lifecycle state.
    func state(_ id: UUID) async -> ProposalState

    /// Mark applied — after the applier succeeds — by `actor`, which the
    /// applied event carries.
    @discardableResult
    func markApplied(_ id: UUID, by actor: ApplyActor) async -> Bool

    /// Mark rejected (the user clicked Reject in the strip).
    @discardableResult
    func markRejected(_ id: UUID) async -> Bool

    /// Withdraw — the *agent* retracted its own pending proposal. Same
    /// effect as reject but a different audit category.
    @discardableResult
    func withdraw(_ id: UUID) async -> Bool

    /// Record that apply threw, and why. The item stays in the queue (user
    /// can retry); `state` reports `.failed`, and `failureReason` the
    /// reason, until the next attempt or resolution.
    @discardableResult
    func markApplyFailed(_ id: UUID, reason: String?) async -> Bool

    /// Why the last apply of a pending proposal failed; nil when it has not.
    func failureReason(_ id: UUID) async -> String?

    /// Claim a pending proposal for applying. False when it is not pending
    /// or already being applied — so one change never applies twice.
    /// Released by `markApplied`, `markApplyFailed` or any resolution.
    func beginApply(_ id: UUID) async -> Bool
}

/// In-memory implementation with optional disk journaling.
///
/// Keeps a small ring of tombstones so `state(_:)` can answer "applied"
/// or "rejected" for a short window after the proposal leaves the live
/// queue (matches the ~5 min window VT documented for
/// `get_proposal_state`). When a journal is provided, pending items
/// rehydrate under their original ids across restarts; resolved ids
/// cannot apply twice for the tombstone TTL.
public actor InMemoryProposalStore: ProposalStore {
    private var pending: [UUID: PendingProposal] = [:]
    private var pendingOrder: [UUID] = []
    private var kindByID: [UUID: String] = [:]   // surfaced into events post-resolve
    private var failedIDs: Set<UUID> = []
    private var failureReasons: [UUID: String] = [:]
    /// Being applied now. Not journaled: after a restart an interrupted
    /// apply is simply pending again.
    private var applyingIDs: Set<UUID> = []
    private var tombstones: [(UUID, ProposalState, Date)] = []
    private let eventLog: EventLog?
    private let journal: DiskPersistence<ProposalJournal>?
    /// How long resolved tombstones stay queryable. 5 minutes is what VT
    /// found agents needed for `get_proposal_state` round-trips.
    public let tombstoneTTL: TimeInterval = 5 * 60
    /// Hard cap on tombstone count even if TTL has not elapsed; defends
    /// against memory growth in long-lived sessions.
    public let tombstoneCap: Int = 256
    /// An expiry is remembered for a day: the agent that proposed may ask
    /// about it long after the five minutes other outcomes are kept.
    public let expiredTombstoneTTL: TimeInterval = 24 * 60 * 60
    /// The clock the lifetime is measured on; a test's own.
    private let now: @Sendable () -> Date

    public init(eventLog: EventLog? = nil, journal: DiskPersistence<ProposalJournal>? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.eventLog = eventLog
        self.journal = journal
        self.now = now
        if let journal, let snap = journal.read() {
            for p in snap.pending {
                pending[p.id] = p
                pendingOrder.append(p.id)
                kindByID[p.id] = p.kind
            }
            failedIDs = Set(snap.failedIDs)
            for (key, reason) in snap.failureReasons ?? [:] {
                if let id = UUID(uuidString: key), failedIDs.contains(id) { failureReasons[id] = reason }
            }
            let current = now()
            let shortTTL = tombstoneTTL, expiredTTL = expiredTombstoneTTL
            let liveTombs = snap.tombstones.filter {
                $0.resolvedAt >= current.addingTimeInterval(-($0.state == .expired ? expiredTTL : shortTTL))
            }
            tombstones = liveTombs.map { ($0.id, $0.state, $0.resolvedAt) }
            // Persist GC using locals so actor init does not hop back onto self.
            if liveTombs.count != snap.tombstones.count {
                journal.write(ProposalJournal(
                    pending: snap.pending,
                    tombstones: liveTombs,
                    failedIDs: snap.failedIDs,
                    failureReasons: snap.failureReasons
                ))
            }
        }
    }

    public func enqueue(_ proposal: PendingProposal) async -> PendingProposal {
        await expireStale()
        pending[proposal.id] = proposal
        pendingOrder.append(proposal.id)
        kindByID[proposal.id] = proposal.kind
        failedIDs.remove(proposal.id)
        failureReasons.removeValue(forKey: proposal.id)
        persist()
        if let eventLog {
            await eventLog.append(.proposalArrived(
                id: proposal.id,
                kind: proposal.kind,
                originKind: AuditOrigin.from(proposal.origin).tag
            ))
        }
        return proposal
    }

    // `list`, `state` and `beginApply` first let go of what has waited too
    // long, so no answer — and no apply — sees a proposal past its time.
    public func list(origin: OperationOrigin? = nil) async -> [PendingProposal] {
        await expireStale()
        let all = pendingOrder.compactMap { pending[$0] }
        guard let origin else { return all }
        return all.filter { $0.origin == origin }
    }

    public func state(_ id: UUID) async -> ProposalState {
        await expireStale()
        gcTombstones()
        if pending[id] != nil {
            if applyingIDs.contains(id) { return .applying }
            return failedIDs.contains(id) ? .failed : .pending
        }
        if let hit = tombstones.first(where: { $0.0 == id }) { return hit.1 }
        return .unknown
    }

    @discardableResult
    public func markApplied(_ id: UUID, by actor: ApplyActor) async -> Bool { await resolve(id, as: .applied, by: actor) }

    @discardableResult
    public func markRejected(_ id: UUID) async -> Bool { await resolve(id, as: .rejected) }

    @discardableResult
    public func withdraw(_ id: UUID) async -> Bool { await resolve(id, as: .withdrawn) }

    public func beginApply(_ id: UUID) async -> Bool {
        await expireStale()
        guard pending[id] != nil, !applyingIDs.contains(id) else { return false }
        applyingIDs.insert(id)
        // A new attempt: the last one's failure is no longer the news.
        failedIDs.remove(id)
        failureReasons.removeValue(forKey: id)
        return true
    }

    @discardableResult
    public func markApplyFailed(_ id: UUID, reason: String?) async -> Bool {
        guard pending[id] != nil else { return false }
        applyingIDs.remove(id)
        failedIDs.insert(id)
        failureReasons[id] = reason.flatMap { $0.isEmpty ? nil : $0 }
        persist()
        if let eventLog {
            let kind = kindByID[id] ?? ""
            await eventLog.append(.proposalFailed(id: id, kind: kind))
        }
        return true
    }

    public func failureReason(_ id: UUID) -> String? {
        failedIDs.contains(id) ? failureReasons[id] : nil
    }

    // MARK: - Internals

    private func resolve(_ id: UUID, as state: ProposalState, by actor: ApplyActor = .person) async -> Bool {
        guard pending.removeValue(forKey: id) != nil else { return false }
        if let i = pendingOrder.firstIndex(of: id) {
            pendingOrder.remove(at: i)
        }
        failedIDs.remove(id)
        failureReasons.removeValue(forKey: id)
        applyingIDs.remove(id)
        let kind = kindByID.removeValue(forKey: id) ?? ""
        tombstones.append((id, state, now()))
        if tombstones.count > tombstoneCap {
            tombstones.removeFirst(tombstones.count - tombstoneCap)
        }
        persist()
        if let eventLog {
            let event: AgentEvent
            switch state {
            case .applied:    event = .proposalApplied(id: id, kind: kind, by: actor)
            case .rejected:   event = .proposalRejected(id: id, kind: kind)
            case .withdrawn:  event = .proposalWithdrawn(id: id, kind: kind)
            case .failed:
                event = .proposalFailed(id: id, kind: kind)
            case .expired:    event = .proposalExpired(id: id, kind: kind)
            case .pending, .applying, .unknown:
                return true  // shouldn't happen via resolve()
            }
            await eventLog.append(event)
        }
        return true
    }

    private func gcTombstones() {
        let current = now()
        tombstones.removeAll {
            $0.2 < current.addingTimeInterval(-($0.1 == .expired ? expiredTombstoneTTL : tombstoneTTL))
        }
    }

    /// Resolves as `expired` every proposal that has waited out
    /// `PendingProposal.lifetime`; one being applied is left to finish.
    private func expireStale() async {
        let current = now()
        let stale = pendingOrder.filter { id in
            guard let proposal = pending[id], !applyingIDs.contains(id) else { return false }
            return proposal.expiresAt <= current
        }
        for id in stale { _ = await resolve(id, as: .expired) }
    }

    private func persist() {
        guard let journal else { return }
        journal.write(ProposalJournal(
            pending: pendingOrder.compactMap { pending[$0] },
            tombstones: tombstones.map {
                ProposalJournal.Tombstone(id: $0.0, state: $0.1, resolvedAt: $0.2)
            },
            failedIDs: Array(failedIDs),
            failureReasons: failureReasons.isEmpty ? nil
                : Dictionary(uniqueKeysWithValues: failureReasons.map { ($0.key.uuidString, $0.value) })
        ))
    }
}
