// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for the `schedulingGuidance` block added to
/// `list_session_images` output. Closes the 2026-05-15 QA
/// finding "No metadata on cluster capacity — I'd settle for a
/// 'typical schedule time' hint in list_session_images." Static
/// guidance is the v1 — these tests pin the tier shape so a
/// future swap to real telemetry doesn't accidentally drop the
/// fastest-first invariant or omit the 1c/1g default tier.
final class ListSessionImagesGuidanceTests: XCTestCase {

    private func makeTool(
        raw: [(id: String, types: [String])] = []
    ) -> ListSessionImagesTool {
        ListSessionImagesTool(fetch: { raw })
    }

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
    }

    // MARK: - First-tier invariant

    /// The first tier MUST be the 1c/1g/0gpu "fast" shape. This
    /// is the invariant the `launch_headless_job` default-down
    /// logic relies on: agents that scan the guidance and pick
    /// the first tier get the recommended default for free.
    func testFirstTierIsOneCoreOneGigZeroGpu() async throws {
        let out = try await makeTool().handle(.init(type: nil), context: ctx())
        let first = out.schedulingGuidance.tiers.first
        XCTAssertEqual(first?.cores, 1, "first tier must be the recommended 1c/1g/0gpu default")
        XCTAssertEqual(first?.ram, 1)
        XCTAssertEqual(first?.gpus, 0)
        XCTAssertEqual(first?.tier, "fast")
    }

    /// Tier 2 must be the 2c/8g warning shape — Skaha's
    /// server-side default that we explicitly intercept on
    /// `launch_headless_job`. Surfacing it so agents see the
    /// "this is what you'd get if you omitted, and here's why
    /// you don't want it" comparison.
    func testSecondTierIs2c8g() async throws {
        let out = try await makeTool().handle(.init(type: nil), context: ctx())
        let tiers = out.schedulingGuidance.tiers
        XCTAssertGreaterThanOrEqual(tiers.count, 2)
        XCTAssertEqual(tiers[1].cores, 2)
        XCTAssertEqual(tiers[1].ram, 8)
    }

    /// At least one GPU tier must exist so agents driving CUDA
    /// workloads have explicit guidance instead of guessing.
    func testHasAtLeastOneGPUTier() async throws {
        let out = try await makeTool().handle(.init(type: nil), context: ctx())
        let gpuTiers = out.schedulingGuidance.tiers.filter { $0.gpus > 0 }
        XCTAssertFalse(gpuTiers.isEmpty,
                       "GPU asks have distinct queueing behaviour; needs explicit guidance")
    }

    /// Every tier carries a non-empty `advice` string — the
    /// agent's only signal for "when should I use this tier" is
    /// the advice text. Empty advice would mean a tier surfaced
    /// in the response that the agent can't reason about.
    func testEveryTierHasNonEmptyAdvice() async throws {
        let out = try await makeTool().handle(.init(type: nil), context: ctx())
        for tier in out.schedulingGuidance.tiers {
            XCTAssertFalse(tier.advice.isEmpty,
                           "tier \(tier.cores)c/\(tier.ram)g/\(tier.gpus)gpu has no advice text")
        }
    }

    /// The top-level note string mentions the 1c/1g default
    /// explicitly. Agents that read only the note (not the per-
    /// tier breakdown) still get the actionable headline.
    func testNoteMentionsOneCoreDefault() async throws {
        let out = try await makeTool().handle(.init(type: nil), context: ctx())
        let note = out.schedulingGuidance.note
        XCTAssertTrue(note.contains("1 CPU") || note.contains("1c"),
                      "note must surface the 1c default headline; got: \(note)")
    }

    // MARK: - Image listing still works

    func testImageEntriesPassThrough() async throws {
        let out = try await makeTool(raw: [
            (id: "img:a", types: ["headless"]),
            (id: "img:b", types: ["notebook"]),
        ]).handle(.init(type: nil), context: ctx())
        XCTAssertEqual(out.images.map(\.id), ["img:a", "img:b"])
    }

    func testTypeFilterApplied() async throws {
        let out = try await makeTool(raw: [
            (id: "img:a", types: ["headless"]),
            (id: "img:b", types: ["notebook"]),
            (id: "img:c", types: ["headless", "notebook"]),
        ]).handle(.init(type: "headless"), context: ctx())
        XCTAssertEqual(Set(out.images.map(\.id)), ["img:a", "img:c"])
    }

    /// Even when image listing returns nothing (or is filtered
    /// to empty), the schedulingGuidance still surfaces — it's
    /// useful guidance regardless of which images the user has
    /// access to.
    func testGuidancePresentEvenForEmptyImageList() async throws {
        let out = try await makeTool().handle(.init(type: "headless"), context: ctx())
        XCTAssertTrue(out.images.isEmpty)
        XCTAssertFalse(out.schedulingGuidance.tiers.isEmpty,
                       "guidance must surface even with no images visible")
    }
}
