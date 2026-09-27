// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// What packages are called across the probed images, and what is inside one.
final class ImagePackageToolsTests: XCTestCase {

    private let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))

    private func manifest() -> ImageManifest {
        ImageManifest(
            schemaVersion: 3, imageID: "images.canfar.net/skaha/astroml:24.07", contentHash: "h",
            capturedAt: Date(timeIntervalSince1970: 0), osFamily: "ubuntu", osVersion: "22.04", kernel: "unknown",
            dpkgPackages: [.init(name: "zlib1g", version: "1.2"), .init(name: "libc6", version: "2.35")],
            pythonPackages: [.init(name: "numpy", version: "1.26", source: "pip", env: ""),
                             .init(name: "Astropy", version: "6.0", source: "pip", env: ""),
                             .init(name: "torch", version: "2.2", source: "conda", env: "ml")],
            rPackages: [.init(name: "ggplot2", version: "3.4")],
            capabilities: ["fitsio"], pythonVersion: "3.11")
    }

    // MARK: - The sections

    func testSectionsArePythonsThenRThenTheSystemsSortedAndNeverEmpty() {
        let sections = manifest().sections
        XCTAssertEqual(sections.map(\.ecosystem), ["python", "python · ml", "r", "dpkg"])
        XCTAssertEqual(sections[0].packages.map(\.name), ["Astropy", "numpy"])
        XCTAssertEqual(sections[3].packages.map(\.name), ["libc6", "zlib1g"])
    }

    // MARK: - describe_image

    func testDescribingAnImageGivesWhatIsKnownAndWhatMatches() {
        let all = DescribeImageTool.describe(manifest(), filter: "")
        XCTAssertEqual(all.os, "ubuntu 22.04")
        XCTAssertNil(all.kernel, "an unknown kernel is not a kernel")
        XCTAssertEqual(all.pythonVersion, "3.11")
        XCTAssertEqual(all.capturedAt, "1970-01-01T00:00:00Z")
        XCTAssertEqual(all.sections.map(\.count), [2, 1, 1, 2])
        XCTAssertNil(all.message)

        let astropy = DescribeImageTool.describe(manifest(), filter: " ASTRO ")
        XCTAssertEqual(astropy.sections, [.init(ecosystem: "python", count: 1, packages: [.init(name: "Astropy", version: "6.0")])])
        XCTAssertNotNil(DescribeImageTool.describe(manifest(), filter: "casa").message)
    }

    func testAnImageNeverProbedIsNotDescribed() async {
        let tool = DescribeImageTool(manifest: { _ in nil })
        guard case .failed(.unknownTarget(let why)) = await tool.invoke(arguments: Data(#"{"imageID":"h/p/x:1"}"#.utf8), context: ctx) else {
            return XCTFail()
        }
        XCTAssertTrue(why.contains("discover_image_packages"))
    }

    // MARK: - search_packages

    private var vocabulary: AllPackages {
        var all = AllPackages()
        all.python = ["specutils", "astropy-healpix", "astropy", "pyspeckit"]
        all.dpkg = ["libspectre1"]
        return all
    }

    func testPackageNamesMatchAnywhereShortestFirstByEcosystem() {
        let matches = SearchPackagesTool.matches("spec", in: vocabulary, ecosystems: SearchPackagesTool.ecosystems)
        XCTAssertEqual(matches, [.init(ecosystem: "python", count: 2, names: ["pyspeckit", "specutils"]),
                                 .init(ecosystem: "dpkg", count: 1, names: ["libspectre1"])])
        XCTAssertEqual(SearchPackagesTool.matches("ASTROPY", in: vocabulary, ecosystems: ["python"]).first?.names,
                       ["astropy", "astropy-healpix"])
    }

    private struct Found: Decodable { let count: Int; let message: String? }

    func testTheSearchSaysWhenNothingHasBeenProbedAndRefusesAnUnknownEcosystem() async throws {
        let empty = SearchPackagesTool(vocabulary: { AllPackages() })
        guard case .data(let data) = await empty.invoke(arguments: Data(#"{"query":"x"}"#.utf8), context: ctx) else { return XCTFail() }
        XCTAssertTrue(try JSONDecoder().decode(Found.self, from: data).message?.contains("discover_image_packages") == true)

        let tool = SearchPackagesTool(vocabulary: { [vocabulary] in vocabulary })
        guard case .failed(.invalidArgument) = await tool.invoke(arguments: Data(#"{"query":"x","ecosystem":"conda"}"#.utf8), context: ctx) else {
            return XCTFail()
        }
        guard case .data(let only) = await tool.invoke(arguments: Data(#"{"query":"spec","ecosystem":"dpkg"}"#.utf8), context: ctx) else {
            return XCTFail()
        }
        XCTAssertEqual(try JSONDecoder().decode(Found.self, from: only).count, 1)
    }
}
