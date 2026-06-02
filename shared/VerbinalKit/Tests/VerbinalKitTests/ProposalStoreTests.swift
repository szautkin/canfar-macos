// SPDX-License-Identifier: MPL-2.0

import XCTest
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
            _ = await store.markApplied(p.id)
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
