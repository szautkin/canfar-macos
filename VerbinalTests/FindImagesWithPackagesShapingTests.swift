// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Pin the new `candidatesToProbe` / `allDiscovered` / type-filter
// behaviour on `find_images_with_packages`. The real cache lives
// behind closures; here we inject stubs to verify the shaping logic
// in isolation — the boundary between three orthogonal signals
// (search, catalogue, discovered) and the composed response shape
// the agent sees.

import XCTest
import VerbinalKit
@testable import Verbinal

final class FindImagesWithPackagesShapingTests: XCTestCase {

    private func makeTool(
        searchResult: [String] = [],
        catalogue: [(id: String, types: [String])] = [],
        discovered: [String] = [],
        partial: [PartialMatch] = []
    ) -> FindImagesWithPackagesTool {
        FindImagesWithPackagesTool(
            search: { _ in searchResult },
            catalogue: { catalogue },
            discoveredIDs: { discovered },
            searchPartial: { _, _, _ in partial }
        )
    }

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 8)
        )
    }

    // MARK: - imageIDs (existing behaviour, regression-pin)

    func testMatchesPassThrough() async throws {
        let tool = makeTool(searchResult: ["a:1", "b:1"])
        let out = try await tool.handle(.init(), context: ctx())
        XCTAssertEqual(Set(out.imageIDs), ["a:1", "b:1"])
    }

    // MARK: - candidatesToProbe

    func testEmptyCacheSurfacesAllCatalogueAsCandidates() async throws {
        // Day-one user: nothing probed. Three catalogue entries.
        // All three should appear as `candidatesToProbe`.
        let tool = makeTool(
            searchResult: [],
            catalogue: [
                (id: "img:a", types: ["headless"]),
                (id: "img:b", types: ["headless"]),
                (id: "img:c", types: ["notebook"]),
            ],
            discovered: []
        )
        let out = try await tool.handle(.init(), context: ctx())
        XCTAssertEqual(Set(out.candidatesToProbe), ["img:a", "img:b", "img:c"])
        XCTAssertTrue(out.imageIDs.isEmpty)
    }

    func testCandidatesExcludeAlreadyDiscovered() async throws {
        // User has probed img:a; only img:b, img:c remain to probe.
        let tool = makeTool(
            catalogue: [
                (id: "img:a", types: ["headless"]),
                (id: "img:b", types: ["headless"]),
                (id: "img:c", types: ["headless"]),
            ],
            discovered: ["img:a"]
        )
        let out = try await tool.handle(.init(), context: ctx())
        XCTAssertEqual(Set(out.candidatesToProbe), ["img:b", "img:c"])
        XCTAssertFalse(out.candidatesToProbe.contains("img:a"))
    }

    func testCandidatesExcludeAlreadyMatched() async throws {
        // img:a matches the query (so it shows up in imageIDs);
        // candidates should suggest the OTHER catalogue entries,
        // not include the match.
        let tool = makeTool(
            searchResult: ["img:a"],
            catalogue: [
                (id: "img:a", types: ["headless"]),
                (id: "img:b", types: ["headless"]),
            ],
            discovered: ["img:a"]
        )
        let out = try await tool.handle(.init(), context: ctx())
        XCTAssertEqual(out.imageIDs, ["img:a"])
        XCTAssertEqual(out.candidatesToProbe, ["img:b"],
            "candidatesToProbe must not duplicate the match list")
    }

    func testCandidatesAreSortedForStableOrder() async throws {
        // Stable ordering across calls — agents comparing
        // responses shouldn't see candidates flip turn-to-turn.
        let tool = makeTool(
            catalogue: [
                (id: "z:1", types: ["headless"]),
                (id: "a:1", types: ["headless"]),
                (id: "m:1", types: ["headless"]),
            ]
        )
        let out = try await tool.handle(.init(), context: ctx())
        XCTAssertEqual(out.candidatesToProbe, ["a:1", "m:1", "z:1"])
    }

    func testCandidatesCappedAtTen() async throws {
        // The cap protects responses from flooding the agent's
        // context. 15 catalogue entries → 10 candidates max.
        let catalogue = (1...15).map { i in
            (id: String(format: "img:%02d", i), types: ["headless"])
        }
        let tool = makeTool(catalogue: catalogue)
        let out = try await tool.handle(.init(), context: ctx())
        XCTAssertEqual(out.candidatesToProbe.count, 10)
        // Sorted, so the first 10 alphabetically.
        XCTAssertEqual(out.candidatesToProbe.first, "img:01")
    }

    // MARK: - type filter

    func testTypeFilterScopesCandidatesToMatchingTypes() async throws {
        let tool = makeTool(
            catalogue: [
                (id: "head:a", types: ["headless"]),
                (id: "note:a", types: ["notebook"]),
                (id: "head:b", types: ["headless"]),
            ]
        )
        var args = FindImagesWithPackagesTool.Args()
        args.type = "headless"
        let out = try await tool.handle(args, context: ctx())
        XCTAssertEqual(Set(out.candidatesToProbe), ["head:a", "head:b"],
            "notebook image must not appear in headless candidates")
    }

    func testTypeFilterScopesAllDiscoveredAndCoverage() async throws {
        // User has probed 1 headless + 1 notebook. When
        // `type: "headless"` is set, `allDiscovered` and the
        // coverage block must report only the headless slice.
        let tool = makeTool(
            catalogue: [
                (id: "head:a", types: ["headless"]),
                (id: "head:b", types: ["headless"]),
                (id: "note:a", types: ["notebook"]),
            ],
            discovered: ["head:a", "note:a"]
        )
        var args = FindImagesWithPackagesTool.Args()
        args.type = "headless"
        let out = try await tool.handle(args, context: ctx())
        XCTAssertEqual(out.allDiscovered, ["head:a"],
            "type filter must scope allDiscovered too")
        XCTAssertEqual(out.coverage.total, 2,
            "type-filtered coverage.total must be only headless catalogue entries")
        XCTAssertEqual(out.coverage.discovered, 1)
    }

    func testTypeFilterIsCaseInsensitive() async throws {
        let tool = makeTool(
            catalogue: [(id: "head:a", types: ["Headless"])]
        )
        var args = FindImagesWithPackagesTool.Args()
        args.type = "headless"
        let out = try await tool.handle(args, context: ctx())
        XCTAssertEqual(out.candidatesToProbe, ["head:a"],
            "type filter must match case-insensitively against the manifest's `types`")
    }

    // MARK: - allDiscovered

    func testAllDiscoveredReturnsEveryProbedImage() async throws {
        let tool = makeTool(
            searchResult: ["a:1"],  // only a:1 matches the query
            catalogue: [
                (id: "a:1", types: ["headless"]),
                (id: "b:1", types: ["headless"]),
            ],
            discovered: ["a:1", "b:1"]  // both probed
        )
        let out = try await tool.handle(.init(), context: ctx())
        XCTAssertEqual(out.imageIDs, ["a:1"], "matches stay scoped to the query")
        XCTAssertEqual(Set(out.allDiscovered), ["a:1", "b:1"],
            "allDiscovered surfaces probed-but-not-matching too — the agent's existing knowledge")
    }

    // MARK: - empty-catalogue degraded mode

    func testEmptyCatalogueDoesNotCrash() async throws {
        // Pre-auth or auth-failed: catalogue closure returns empty.
        // Tool must still produce a coherent response.
        let tool = makeTool()
        let out = try await tool.handle(.init(), context: ctx())
        XCTAssertEqual(out.coverage.total, 0)
        XCTAssertTrue(out.candidatesToProbe.isEmpty)
        XCTAssertTrue(out.allDiscovered.isEmpty)
    }
}
