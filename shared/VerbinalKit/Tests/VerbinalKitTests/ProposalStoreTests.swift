// SPDX-License-Identifier: MPL-2.0

import XCTest
import os
@testable import VerbinalKit

/// Ticket 031: confirms `InMemoryProposalStore.list(origin:)` and
/// `state(_:)` — written without the `async` keyword yet satisfying the
/// `async` `ProposalStore` requirements via actor isolation — return
/// correct results when awaited from outside the actor, and that the
/// tombstone *cap* (the part of "TTL/cap" not covered by the existing
/// `InMemoryProposalStoreTests`) still bounds retained resolutions.
final class ProposalStoreCapAndIsolationTests: XCTestCase {

    private func makeProposal(origin: OperationOrigin) -> PendingProposal {
        PendingProposal(
            toolName: "test_tool",
            kind: "k",
            summary: "s",
            payload: Data("{}".utf8),
            origin: origin
        )
    }

    /// `list` and `state` are bare (non-`async`) on the actor but must be
    /// awaited from outside it; exercise that round-trip end-to-end.
    func testListAndStateAwaitedFromOutsideActor() async {
        let store = InMemoryProposalStore()
        let userProp = makeProposal(origin: .user)
        let extProp = makeProposal(origin: .external(clientID: "c1"))
        _ = await store.enqueue(userProp)
        _ = await store.enqueue(extProp)

        let all = await store.list(origin: nil)
        XCTAssertEqual(all.map(\.id), [userProp.id, extProp.id])

        let onlyUser = await store.list(origin: .user)
        XCTAssertEqual(onlyUser.map(\.id), [userProp.id])

        let pendingState = await store.state(extProp.id)
        XCTAssertEqual(pendingState, .pending)
    }

    func testTombstoneCapBoundsRetainedResolutions() async {
        let store = InMemoryProposalStore()
        let cap = await store.tombstoneCap

        // Enqueue + resolve more proposals than the cap; the earliest
        // tombstones must be evicted so `state(_:)` answers `.unknown`
        // for them while the most recent ones remain queryable.
        var ids: [UUID] = []
        for _ in 0..<(cap + 5) {
            let p = makeProposal(origin: .user)
            ids.append(p.id)
            _ = await store.enqueue(p)
            _ = await store.markApplied(p.id, by: .person)
        }

        // The first 5 should have been pushed out of the tombstone ring.
        for id in ids.prefix(5) {
            let s = await store.state(id)
            XCTAssertEqual(s, .unknown)
        }
        // The most recent resolution is still retained.
        let last = await store.state(ids[ids.count - 1])
        XCTAssertEqual(last, .applied)
    }
}

/// Plan 15 S4 (QA L18): a pending proposal expires after
/// `PendingProposal.lifetime` — one sat in Pending for six days — and
/// says so, to `state` and on the event log.
final class ProposalExpiryTests: XCTestCase {

    /// A clock the test moves.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func proposal(at date: Date) -> PendingProposal {
        PendingProposal(toolName: "save_query", kind: "save_query", summary: "Save", payload: Data("{}".utf8),
                        createdAt: date, origin: .external(clientID: "c"))
    }

    func testAProposalExpiresAfterItsLifetimeAndSaysSo() async {
        XCTAssertEqual(PendingProposal.lifetime, 3 * 60 * 60, "the person chose three hours")
        let clock = Clock(start)
        let log = EventLog()
        let store = InMemoryProposalStore(eventLog: log, now: { clock.now })
        let waiting = await store.enqueue(proposal(at: start))

        clock.advance(PendingProposal.lifetime - 60)
        let justBefore = await store.state(waiting.id)
        XCTAssertEqual(justBefore, .pending)

        clock.advance(60)
        let listed = await store.list(origin: nil)
        let state = await store.state(waiting.id)
        let applies = await store.beginApply(waiting.id)
        XCTAssertTrue(listed.isEmpty)
        XCTAssertEqual(state, .expired)
        XCTAssertFalse(applies, "an expired proposal cannot be applied")
        let events = await log.snapshot().map(\.event)
        XCTAssertEqual(events.last, .proposalExpired(id: waiting.id, kind: "save_query"))

        clock.advance(60 * 60)
        let anHourLater = await store.state(waiting.id)
        XCTAssertEqual(anHourLater, .expired, "an expiry is remembered longer than other outcomes")
        clock.advance(24 * 60 * 60)
        let aDayLater = await store.state(waiting.id)
        XCTAssertEqual(aDayLater, .unknown)
    }

    func testOneBeingAppliedIsLeftToFinish() async {
        let clock = Clock(start)
        let store = InMemoryProposalStore(now: { clock.now })
        let running = await store.enqueue(proposal(at: start))
        _ = await store.beginApply(running.id)
        clock.advance(PendingProposal.lifetime * 2)
        let state = await store.state(running.id)
        XCTAssertEqual(state, .applying)
    }

    /// The reported case: a proposal left in the journal for six days.
    func testAnOldProposalFromTheJournalExpires() async throws {
        let journal = DiskPersistence<ProposalJournal>(subdirectory: "ProposalExpiryTests-\(UUID().uuidString)",
                                                       fileName: "pending.json", logger: .init())
        defer { journal.delete() }
        let old = proposal(at: start.addingTimeInterval(-6 * 24 * 60 * 60))
        journal.write(ProposalJournal(pending: [old], tombstones: [], failedIDs: []))

        let store = InMemoryProposalStore(journal: journal, now: { self.start })
        let listed = await store.list(origin: nil)
        let state = await store.state(old.id)
        XCTAssertTrue(listed.isEmpty)
        XCTAssertEqual(state, .expired)
        XCTAssertTrue(journal.read()?.pending.isEmpty == true, "and the journal no longer holds it")
    }
}
