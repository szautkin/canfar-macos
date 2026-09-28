// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

final class EventLogTests: XCTestCase {

    func testAppendIncrementsToken() async {
        let log = EventLog()
        let id = UUID()
        let t1 = await log.append(.proposalArrived(id: id, kind: "x", originKind: "user"))
        let t2 = await log.append(.proposalApplied(id: id, kind: "x", by: .person))
        XCTAssertEqual(t1, 1)
        XCTAssertEqual(t2, 2)
    }

    func testEntriesSinceFiltersByToken() async {
        let log = EventLog()
        let id = UUID()
        _ = await log.append(.proposalArrived(id: id, kind: "x", originKind: "user")) // 1
        _ = await log.append(.proposalApplied(id: id, kind: "x", by: .person)) // 2
        _ = await log.append(.proposalRejected(id: UUID(), kind: "y")) // 3
        let result = await log.entries(since: 1)
        XCTAssertEqual(result.entries.map(\.token), [2, 3])
        XCTAssertFalse(result.expired)
    }

    func testEntriesSinceZeroReturnsAll() async {
        let log = EventLog()
        _ = await log.append(.proposalArrived(id: UUID(), kind: "k", originKind: "ext"))
        let result = await log.entries(since: 0)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertFalse(result.expired)
    }

    func testRingTrimsAtCapacity() async {
        let log = EventLog(capacity: 3)
        for _ in 0..<5 {
            _ = await log.append(.proposalArrived(id: UUID(), kind: "k", originKind: "u"))
        }
        let snap = await log.snapshot()
        XCTAssertEqual(snap.count, 3)
        XCTAssertEqual(snap.map(\.token), [3, 4, 5])
    }

    func testExpiredFlagWhenTokenBelowEarliest() async {
        let log = EventLog(capacity: 2)
        for _ in 0..<5 {
            _ = await log.append(.proposalArrived(id: UUID(), kind: "k", originKind: "u"))
        }
        // Earliest retained is token=4. Asking since=1 should mark expired.
        let result = await log.entries(since: 1)
        XCTAssertTrue(result.expired)
    }

    func testCurrentTokenAwaitedFromOutsideActor() async {
        let log = EventLog()
        // Empty log reports 0 (no entries yet).
        let empty = await log.currentToken()
        XCTAssertEqual(empty, 0)

        _ = await log.append(.proposalArrived(id: UUID(), kind: "k", originKind: "u"))
        _ = await log.append(.proposalApplied(id: UUID(), kind: "k", by: .person))
        let current = await log.currentToken()
        XCTAssertEqual(current, 2)
    }

    func testStoreFanOutOnLifecycle() async {
        let log = EventLog()
        let store = InMemoryProposalStore(eventLog: log)
        let proposal = PendingProposal(
            toolName: "test_tool",
            kind: "k",
            summary: "s",
            payload: Data("{}".utf8),
            origin: .user
        )
        _ = await store.enqueue(proposal)
        let didApply = await store.markApplied(proposal.id, by: .person)
        XCTAssertTrue(didApply)
        let snap = await log.snapshot()
        XCTAssertEqual(snap.count, 2)
        if case .proposalArrived(_, let k, _) = snap[0].event {
            XCTAssertEqual(k, "k")
        } else { XCTFail("expected proposalArrived first") }
        if case .proposalApplied = snap[1].event {} else {
            XCTFail("expected proposalApplied second")
        }
    }

    /// Plan 15 S2 (QA H7): the applied event says who applied it, so a
    /// person's click and auto-apply are told apart without timing.
    func testTheAppliedEventSaysWhoAppliedIt() async {
        let log = EventLog()
        let store = InMemoryProposalStore(eventLog: log)
        for actor in ApplyActor.allCases {
            let proposal = PendingProposal(toolName: "t", kind: actor.rawValue, summary: "s",
                                           payload: Data("{}".utf8), origin: .user)
            _ = await store.enqueue(proposal)
            _ = await store.markApplied(proposal.id, by: actor)
        }
        let applied = await log.snapshot().compactMap { entry -> ApplyActor? in
            if case .proposalApplied(_, _, let actor) = entry.event { return actor }
            return nil
        }
        XCTAssertEqual(applied, ApplyActor.allCases)
    }
}
