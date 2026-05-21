// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for the `recursive: true` mode added to
/// `delete_vospace_node` in response to the 2026-05-15 QA
/// finding that cleaning up `__pycache__` required three
/// separate tool calls (list → delete leaves → delete dir).
/// These tests pin the plan/payload contract; the actual
/// network walk is tested via the integration suite when a
/// VOSpace fixture is available.
final class RecursiveDeleteVOSpaceTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
    }

    /// Default `recursive` is false. The summary must match the
    /// pre-existing single-node delete language so existing
    /// agent transcripts stay comparable.
    func testNonRecursiveDefaultPlan() async throws {
        let tool = DeleteVOSpaceNodeTool()
        let plan = try await tool.plan(
            .init(path: "foo/bar.txt", recursive: nil),
            context: ctx()
        )
        XCTAssertEqual(plan.summary, "Delete from VOSpace: foo/bar.txt")
        let payload = try JSONDecoder().decode(
            DeleteVOSpaceNodeTool.Payload.self,
            from: plan.payload
        )
        XCTAssertFalse(payload.recursive)
        XCTAssertEqual(payload.path, "foo/bar.txt")
    }

    /// Explicit `recursive: false` reads identical to omission —
    /// the boolean defaults to false everywhere along the path.
    func testExplicitNonRecursivePlan() async throws {
        let tool = DeleteVOSpaceNodeTool()
        let plan = try await tool.plan(
            .init(path: "foo", recursive: false),
            context: ctx()
        )
        XCTAssertEqual(plan.summary, "Delete from VOSpace: foo")
        let payload = try JSONDecoder().decode(
            DeleteVOSpaceNodeTool.Payload.self,
            from: plan.payload
        )
        XCTAssertFalse(payload.recursive)
    }

    /// `recursive: true` must change the summary to include both
    /// the "Recursively" verb AND the cap — the human approver
    /// reading the strip needs to see that a folder will be
    /// wiped, not just one file.
    func testRecursivePlanSummary() async throws {
        let tool = DeleteVOSpaceNodeTool()
        let plan = try await tool.plan(
            .init(path: "compact-groups/v1", recursive: true),
            context: ctx()
        )
        XCTAssertTrue(plan.summary.contains("Recursively"),
                      "summary must signal recursion; got: \(plan.summary)")
        XCTAssertTrue(plan.summary.contains("compact-groups/v1"),
                      "summary must name the path; got: \(plan.summary)")
        XCTAssertTrue(plan.summary.contains("100"),
                      "summary must surface the cap; got: \(plan.summary)")
    }

    /// Payload propagates the recursive flag so the applier can
    /// pick the right code path.
    func testRecursivePayloadPropagatesFlag() async throws {
        let tool = DeleteVOSpaceNodeTool()
        let plan = try await tool.plan(
            .init(path: "tmp", recursive: true),
            context: ctx()
        )
        let payload = try JSONDecoder().decode(
            DeleteVOSpaceNodeTool.Payload.self,
            from: plan.payload
        )
        XCTAssertTrue(payload.recursive)
        XCTAssertEqual(payload.path, "tmp")
    }

    /// Empty path is rejected at plan time — the applier never
    /// sees it, and the agent gets a typed error fast.
    func testEmptyPathRejected() async {
        let tool = DeleteVOSpaceNodeTool()
        do {
            _ = try await tool.plan(
                .init(path: "", recursive: true),
                context: ctx()
            )
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else {
                XCTFail("wrong typed case: \(f)")
                return
            }
        } catch {
            XCTFail("expected ToolFailureReason; got \(error)")
        }
    }

    /// Cap is a deliberate safety bound — pin its value so a
    /// future change doesn't silently raise it (or lower it
    /// past usefulness for typical cleanups).
    func testRecursiveDeleteCapValue() {
        XCTAssertEqual(DeleteVOSpaceNodeTool.recursiveDeleteCap, 100,
                       "cap balances `__pycache__`-shaped cleanups against catastrophic misclick risk; change deliberately")
    }
}
