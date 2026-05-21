// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for `PackageQuery.score(_:)` and the integration with
/// `find_images_with_packages`. Closes the 2026-05-15 QA finding:
/// asking for `[astropy, scipy, astroquery, numpy, fitsio, python3]`
/// returned 0 strict matches because no image had all six, even
/// though four had three or more. Partial scoring gives the agent
/// a ranked near-miss list instead of an unhelpful empty response.
final class PartialMatchScoringTests: XCTestCase {

    // MARK: - Fixtures

    private func pkg(_ name: String) -> ImageManifest.Package {
        ImageManifest.Package(name: name, version: "1.0")
    }

    private func pypkg(_ name: String) -> ImageManifest.PythonPackage {
        ImageManifest.PythonPackage(name: name, version: "1.0", source: "pip", env: "")
    }

    private func manifest(
        osFamily: String = "ubuntu",
        osVersion: String = "22.04",
        dpkg: [String] = [],
        python: [String] = [],
        capabilities: [String] = []
    ) -> ImageManifest {
        ImageManifest(
            schemaVersion: 2,
            imageID: "test/image:1.0",
            contentHash: "sha256:test",
            capturedAt: Date(),
            osFamily: osFamily,
            osVersion: osVersion,
            kernel: "test",
            dpkgPackages: dpkg.map(pkg),
            rpmPackages: [],
            apkPackages: [],
            pythonPackages: python.map(pypkg),
            rPackages: [],
            condaEnvs: [],
            probeNotes: nil,
            capabilities: capabilities
        )
    }

    // MARK: - PackageQuery.score

    /// An empty query has no constraints; every manifest trivially
    /// satisfies "nothing." Score must read 1.0 with no missing
    /// list. The store layer relies on this to short-circuit
    /// partial-match output to empty when the user supplied no
    /// filters (returning every manifest with score 1.0 would
    /// flood the response).
    func testEmptyQueryScoresOne() {
        let q = PackageQuery()
        let (score, missing) = q.score(manifest())
        XCTAssertEqual(score, 1.0, accuracy: 0.0001)
        XCTAssertTrue(missing.isEmpty)
    }

    /// One python constraint, satisfied: 1/1 = 1.0, nothing
    /// missing.
    func testSingleSatisfiedConstraintScoresOne() {
        var q = PackageQuery()
        q.python = ["astropy"]
        let (score, missing) = q.score(manifest(python: ["astropy"]))
        XCTAssertEqual(score, 1.0, accuracy: 0.0001)
        XCTAssertTrue(missing.isEmpty)
    }

    /// One python constraint, not satisfied: 0/1 = 0.0, missing
    /// list names it with the `python:` prefix so agents reading
    /// the output can tell which category each entry belongs to.
    func testSingleMissingConstraintScoresZero() {
        var q = PackageQuery()
        q.python = ["fitsio"]
        let (score, missing) = q.score(manifest(python: []))
        XCTAssertEqual(score, 0.0, accuracy: 0.0001)
        XCTAssertEqual(missing, ["python:fitsio"])
    }

    /// The QA-named example: 6 python packages requested, 5
    /// satisfied. Score must be 5/6 (~0.833) with the one
    /// missing entry tagged `python:<name>`.
    func testQAExampleFiveOfSixSatisfied() {
        var q = PackageQuery()
        q.python = ["astropy", "scipy", "astroquery", "numpy", "fitsio", "python3"]
        let (score, missing) = q.score(manifest(
            python: ["astropy", "scipy", "astroquery", "numpy", "python3"]
        ))
        XCTAssertEqual(score, 5.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(missing, ["python:fitsio"])
    }

    /// Mixed categories: 1 OS + 1 dpkg + 2 python, with dpkg and
    /// one python missing. Total constraints = 4; satisfied = 2;
    /// score = 0.5.
    func testMixedCategoriesPartialSatisfaction() {
        var q = PackageQuery()
        q.osFamilies = ["ubuntu"]
        q.dpkg = ["libfftw3-dev"]
        q.python = ["astropy", "fitsio"]
        let m = manifest(
            osFamily: "ubuntu",
            dpkg: [],
            python: ["astropy"]
        )
        let (score, missing) = q.score(m)
        XCTAssertEqual(score, 2.0 / 4.0, accuracy: 0.0001)
        XCTAssertTrue(missing.contains("dpkg:libfftw3-dev"))
        XCTAssertTrue(missing.contains("python:fitsio"))
        XCTAssertFalse(missing.contains("osFamily"))
    }

    /// OS family mismatch: marker entry is `"osFamily"` (no
    /// per-value detail — the constraint set may have many
    /// acceptable values).
    func testOsFamilyMissingMarker() {
        var q = PackageQuery()
        q.osFamilies = ["alpine"]
        let (_, missing) = q.score(manifest(osFamily: "ubuntu"))
        XCTAssertEqual(missing, ["osFamily"])
    }

    /// Capability missing: tagged `capability:<name>` so the
    /// caller can distinguish "you asked for gpu and the image
    /// doesn't have one" from "you asked for python:gpu and it's
    /// missing from pip" (a different problem with a different
    /// fix).
    func testCapabilityMissingTaggedExplicitly() {
        var q = PackageQuery()
        q.capabilities = ["gpu", "fitsio"]
        let (score, missing) = q.score(manifest(capabilities: ["fitsio"]))
        XCTAssertEqual(score, 1.0 / 2.0, accuracy: 0.0001)
        XCTAssertEqual(missing, ["capability:gpu"])
    }

    // MARK: - find_images_with_packages: integration

    /// Strict match empty + non-empty query: partialMatches
    /// populated. This is the QA-named use case — the user
    /// over-specified and the strict-AND came up dry; the
    /// near-miss list lets the agent recover.
    func testStrictEmptyQueryNonEmptyPopulatesPartials() async throws {
        let partials = [
            PartialMatch(imageID: "img:near", score: 0.83, missing: ["python:fitsio"]),
            PartialMatch(imageID: "img:other", score: 0.66, missing: ["python:fitsio", "python:photutils"]),
        ]
        let tool = FindImagesWithPackagesTool(
            search: { _ in [] },
            catalogue: { [(id: "img:near", types: ["headless"]), (id: "img:other", types: ["headless"])] },
            discoveredIDs: { ["img:near", "img:other"] },
            searchPartial: { _, _, _ in partials }
        )
        let ctx = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
        var args = FindImagesWithPackagesTool.Args()
        args.python = ["astropy", "scipy", "astroquery", "numpy", "fitsio", "python3"]
        let out = try await tool.handle(args, context: ctx)
        XCTAssertTrue(out.imageIDs.isEmpty)
        XCTAssertEqual(out.partialMatches.count, 2)
        XCTAssertEqual(out.partialMatches.first?.imageID, "img:near")
        XCTAssertEqual(out.partialMatches.first?.score ?? 0, 0.83, accuracy: 0.0001)
        XCTAssertEqual(out.partialMatches.first?.missing, ["python:fitsio"])
    }

    /// Strict match non-empty: partialMatches is empty even if
    /// the searchPartial closure would have returned something.
    /// Rationale: agent has actionable hits; adding a parallel
    /// near-miss list clutters reasoning.
    func testStrictMatchEmptyPartials() async throws {
        let tool = FindImagesWithPackagesTool(
            search: { _ in ["img:hit"] },
            catalogue: { [(id: "img:hit", types: ["headless"])] },
            discoveredIDs: { ["img:hit"] },
            searchPartial: { _, _, _ in
                // The wireup wouldn't typically be called when
                // imageIDs is non-empty, but if it were the tool
                // must still suppress the field — assert by
                // returning a fake value the tool must drop.
                [PartialMatch(imageID: "img:fake", score: 0.5, missing: [])]
            }
        )
        let ctx = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
        var args = FindImagesWithPackagesTool.Args()
        args.python = ["astropy"]
        let out = try await tool.handle(args, context: ctx)
        XCTAssertEqual(out.imageIDs, ["img:hit"])
        XCTAssertTrue(out.partialMatches.isEmpty,
                      "partialMatches must be empty when strict match returned hits")
    }

    /// Empty query AND strict empty: partialMatches still empty
    /// (every manifest scores 1.0; flooding the response is
    /// useless).
    func testEmptyQueryYieldsEmptyPartials() async throws {
        let tool = FindImagesWithPackagesTool(
            search: { _ in [] },
            catalogue: { [] },
            discoveredIDs: { [] },
            searchPartial: { _, _, _ in
                XCTFail("searchPartial must not be invoked for an empty query")
                return []
            }
        )
        let ctx = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
        let out = try await tool.handle(.init(), context: ctx)
        XCTAssertTrue(out.partialMatches.isEmpty)
        XCTAssertTrue(out.unfiltered)
    }

    /// Type-filter applied to partial matches too: an off-type
    /// near-miss is dropped after scoring. Pins the wireup logic
    /// that filters partials by the same scoped catalogue set.
    func testPartialMatchesRespectTypeFilter() async throws {
        let partials = [
            // off-type: catalogue marks it notebook-only.
            PartialMatch(imageID: "img:notebook-only", score: 0.83, missing: []),
            // on-type: headless.
            PartialMatch(imageID: "img:headless", score: 0.66, missing: []),
        ]
        let tool = FindImagesWithPackagesTool(
            search: { _ in [] },
            catalogue: {
                [
                    (id: "img:notebook-only", types: ["notebook"]),
                    (id: "img:headless", types: ["headless"]),
                ]
            },
            discoveredIDs: { ["img:notebook-only", "img:headless"] },
            searchPartial: { _, _, _ in partials }
        )
        let ctx = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
        var args = FindImagesWithPackagesTool.Args()
        args.python = ["astropy"]
        args.type = "headless"
        let out = try await tool.handle(args, context: ctx)
        XCTAssertEqual(out.partialMatches.map(\.imageID), ["img:headless"])
    }
}
