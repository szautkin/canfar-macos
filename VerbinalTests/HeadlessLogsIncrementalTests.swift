// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for the `since_bytes` incremental-polling addition
/// to `get_headless_job_logs`. Closes the 2026-05-15 QA finding
/// "No log tailing / streaming. Polling logs every `sleep 60`
/// was the only way. For long-running jobs this is wasteful."
/// The `nextOffset` round-trip is a poor person's tail-follow
/// pattern — but a workable one until a true streaming endpoint
/// is wired through Skaha.
final class HeadlessLogsIncrementalTests: XCTestCase {

    // MARK: - makeOutput pure slicing

    /// since=0 returns the full log content; nextOffset equals
    /// the total byte length. This is the day-one poll: caller
    /// hasn't seen any output yet.
    func testSinceZeroReturnsFullLog() {
        let logs = "hello world\nline two\n"
        let out = GetHeadlessJobLogsTool.makeOutput(
            id: "job-1", fullLogs: logs, since: 0, state: "ready"
        )
        XCTAssertEqual(out.logs, logs)
        XCTAssertEqual(out.nextOffset, logs.utf8.count)
        XCTAssertEqual(out.returnedBytes, logs.utf8.count)
        XCTAssertFalse(out.upToDate)
    }

    /// since equal to the total length yields an empty suffix
    /// with `upToDate: true` — the caller's "I've already seen
    /// all of this" signal. Agents pause before polling again
    /// when they see this.
    func testSinceEqualToTotalIsUpToDate() {
        let logs = "line one\nline two\n"
        let total = logs.utf8.count
        let out = GetHeadlessJobLogsTool.makeOutput(
            id: "job-1", fullLogs: logs, since: total, state: "ready"
        )
        XCTAssertEqual(out.logs, "")
        XCTAssertEqual(out.nextOffset, total)
        XCTAssertEqual(out.returnedBytes, 0)
        XCTAssertTrue(out.upToDate)
    }

    /// since past the total clamps to total — no negative
    /// returnedBytes, no crash. Defensive: shouldn't happen
    /// in normal usage, but a caller who cached the offset
    /// from one job and accidentally sent it for another
    /// shouldn't blow up.
    func testSincePastTotalClamps() {
        let logs = "short"
        let out = GetHeadlessJobLogsTool.makeOutput(
            id: "job-1", fullLogs: logs, since: 9999, state: "ready"
        )
        XCTAssertEqual(out.logs, "")
        XCTAssertEqual(out.nextOffset, 5)
        XCTAssertEqual(out.returnedBytes, 0)
        XCTAssertTrue(out.upToDate)
    }

    /// Mid-log since returns only the suffix from that byte.
    /// The QA-named use case: agent polled at byte 20, log
    /// grew to byte 50 — agent gets the 30 new bytes only.
    func testMidLogSinceReturnsSuffix() {
        let logs = "AAAAA BBBBB CCCCC DDDDD"  // 23 bytes
        let out = GetHeadlessJobLogsTool.makeOutput(
            id: "job-1", fullLogs: logs, since: 12, state: "ready"
        )
        XCTAssertEqual(out.logs, "CCCCC DDDDD")
        XCTAssertEqual(out.nextOffset, 23)
        XCTAssertEqual(out.returnedBytes, 11)
        XCTAssertFalse(out.upToDate)
    }

    /// Negative `since` clamps to zero — `Args.since_bytes` is
    /// schema-constrained to ≥0 but we belt-and-suspenders in
    /// `makeOutput` so an internal caller can't accidentally
    /// trip it.
    func testNegativeSinceClampsToZero() {
        let logs = "abcdef"
        let out = GetHeadlessJobLogsTool.makeOutput(
            id: "job-1", fullLogs: logs, since: -5, state: "ready"
        )
        XCTAssertEqual(out.logs, "abcdef")
        XCTAssertEqual(out.returnedBytes, 6)
    }

    /// State pass-through: caller-supplied `"ready"` /
    /// `"pending"` appears in the output verbatim. Pin so the
    /// state machine doesn't accidentally swap meanings.
    func testStatePassesThrough() {
        let out = GetHeadlessJobLogsTool.makeOutput(
            id: "x", fullLogs: "", since: 0, state: "pending"
        )
        XCTAssertEqual(out.state, "pending")
    }

    /// Empty log + since=0 → empty result, upToDate true
    /// (zero bytes read because there are zero bytes to read,
    /// which is the same as "I've seen all of it").
    func testEmptyLogIsUpToDate() {
        let out = GetHeadlessJobLogsTool.makeOutput(
            id: "x", fullLogs: "", since: 0, state: "ready"
        )
        XCTAssertEqual(out.logs, "")
        XCTAssertEqual(out.nextOffset, 0)
        XCTAssertTrue(out.upToDate)
    }

    // MARK: - End-to-end via tool

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
    }

    /// Two-call poll cycle: first call (since unset) returns
    /// the full log and an offset; second call passes the
    /// offset back and receives only the delta. This is the
    /// pattern the QA report asked for.
    func testIncrementalPollSeesOnlyTheDelta() async throws {
        // Simulated Skaha behaviour: log grows over time. The
        // fetch closure returns whatever the current size is
        // at the moment of the call; we mutate it between
        // calls to model the growth.
        let logState = LogState(content: "first chunk\n")
        let tool = GetHeadlessJobLogsTool(fetch: { _ in
            await logState.read()
        })

        let first = try await tool.handle(.init(id: "j", since_bytes: nil), context: ctx())
        XCTAssertEqual(first.logs, "first chunk\n")
        let offset = first.nextOffset

        await logState.append("second chunk\n")

        let second = try await tool.handle(.init(id: "j", since_bytes: offset), context: ctx())
        XCTAssertEqual(second.logs, "second chunk\n",
                       "must receive only the new bytes, not re-fetch the first chunk")
        XCTAssertGreaterThan(second.nextOffset, offset)
        XCTAssertFalse(second.upToDate)

        // Third poll with no new growth: upToDate.
        let third = try await tool.handle(.init(id: "j", since_bytes: second.nextOffset), context: ctx())
        XCTAssertEqual(third.logs, "")
        XCTAssertTrue(third.upToDate)
    }
}

/// Tiny actor backing the simulated growing-log fixture.
/// Keeps the state thread-safe across the async fetches the
/// tool issues without forcing the test to reach for a global
/// `var`.
private actor LogState {
    private var content: String
    init(content: String) { self.content = content }
    func read() -> String { content }
    func append(_ s: String) { content += s }
}
