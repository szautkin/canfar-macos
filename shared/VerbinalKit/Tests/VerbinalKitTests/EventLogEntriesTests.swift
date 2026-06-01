// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// Ticket 001: `EventLog.entries(since:)` hardening — empty-buffer behavior
/// and an expired-flag computation that must not rely on `buffer.first!` or a
/// `earliest - 1` UInt64 underflow. (The general expired/filter cases are
/// already covered by EventLogTests.)
final class EventLogEntriesTests: XCTestCase {

    func testEntriesSinceOnEmptyBufferReturnsEmptyNotExpired() async {
        let log = EventLog(capacity: 8)
        let r0 = await log.entries(since: 0)
        XCTAssertTrue(r0.entries.isEmpty)
        XCTAssertFalse(r0.expired)

        let r42 = await log.entries(since: 42)
        XCTAssertTrue(r42.entries.isEmpty)
        XCTAssertFalse(r42.expired, "an empty buffer is never expired")
    }

    func testExpiredBoundaryDoesNotUnderflow() async {
        // capacity 2 keeps the last two tokens; after 5 appends the earliest
        // retained token is 4.
        let log = EventLog(capacity: 2)
        for _ in 0..<5 {
            _ = await log.append(.proposalArrived(id: UUID(), kind: "k", originKind: "u"))
        }
        let e0 = await log.entries(since: 0).expired
        let e4 = await log.entries(since: 4).expired
        let e3 = await log.entries(since: 3).expired
        let e1 = await log.entries(since: 1).expired
        XCTAssertFalse(e0, "fresh-session sentinel is never expired")
        XCTAssertFalse(e4, "cursor at earliest is not expired")
        XCTAssertFalse(e3, "one behind earliest is the boundary, not expired")
        XCTAssertTrue(e1, "two or more behind earliest is expired")
    }
}
