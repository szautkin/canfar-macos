// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Coverage for `DeleteSessionsBulkTool.plan` — the boundary that
/// rejects empty, oversized, or blank-only id lists before a
/// proposal lands in the queue. The applier itself is parallel-
/// fan-out with per-id error swallowing, so the boundary is where
/// the "what's the user actually asking for" sanity check lives.
final class DeleteSessionsBulkValidationTests: XCTestCase {

    private func plan(_ ids: [String]) async throws -> ProposalPlan {
        let tool = DeleteSessionsBulkTool()
        return try await tool.plan(
            DeleteSessionsBulkTool.Args(ids: ids),
            context: AIToolContext.fake()
        )
    }

    func testSingleIDAccepted() async throws {
        let plan = try await plan(["nx0hjggr"])
        XCTAssertEqual(plan.kind, "delete_sessions_bulk")
        XCTAssertTrue(plan.summary.contains("1 session"))
    }

    func testMultipleIDsAccepted() async throws {
        let plan = try await plan(["a", "b", "c", "d", "e"])
        XCTAssertTrue(plan.summary.contains("5 sessions"))
    }

    func testDuplicatesDeduplicated() async throws {
        // Two of the same id should be deduplicated to one — no
        // point firing two DELETEs for the same session.
        let plan = try await plan(["a", "a", "b"])
        XCTAssertTrue(plan.summary.contains("2 sessions"))
    }

    func testEmptyListRejected() async {
        do {
            _ = try await plan([])
            XCTFail("expected invalidArgument")
        } catch ToolFailureReason.invalidArgument {
            // expected
        } catch {
            XCTFail("expected ToolFailureReason.invalidArgument; got \(error)")
        }
    }

    func testBlanksOnlyRejected() async {
        do {
            _ = try await plan(["", "  ", ""])
            // Empty strings are dropped during dedup; remaining
            // blanks-with-whitespace also have to be rejected by
            // the empty-after-filter check.
            XCTFail("expected invalidArgument")
        } catch ToolFailureReason.invalidArgument {
            // expected — at minimum the all-empty case must throw
        } catch {
            XCTFail("expected ToolFailureReason.invalidArgument; got \(error)")
        }
    }

    func testOverCapRejected() async {
        let many = (1...51).map { "session-\($0)" }
        do {
            _ = try await plan(many)
            XCTFail("expected invalidArgument for >50 ids")
        } catch ToolFailureReason.invalidArgument(let msg) {
            XCTAssertTrue(msg.contains("50"), "cap value must appear in message: \(msg)")
        } catch {
            XCTFail("expected ToolFailureReason.invalidArgument; got \(error)")
        }
    }

    func testCapBoundaryAccepted() async throws {
        // 50 is the inclusive cap; 50 unique ids must pass.
        let max = (1...50).map { "session-\($0)" }
        _ = try await plan(max)
    }
}

private extension AIToolContext {
    /// Minimal context for boundary-test purposes. `plan()` only
    /// reads `context` if the tool's logic happens to consult it
    /// (this one doesn't), so the fields can be no-op stubs.
    static func fake() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 999)
        )
    }
}
