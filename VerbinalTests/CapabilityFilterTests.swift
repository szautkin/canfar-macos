// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Coverage for `PackageQuery.capabilities` filtering and the
/// canonical capability vocabulary that probes emit. Closes the
/// 2026-05-14 QA review's "package-name match can't answer
/// behavioural questions" gap — these tests pin the boundary so
/// future probe / parser changes can't silently desync from the
/// agent-visible capability keys.
final class CapabilityFilterTests: XCTestCase {

    private func manifest(_ caps: [String]) -> ImageManifest {
        ImageManifest(
            schemaVersion: 2,
            imageID: "test/image:1.0",
            contentHash: "sha256:test",
            capturedAt: Date(),
            osFamily: "ubuntu",
            osVersion: "22.04",
            kernel: "test",
            capabilities: caps
        )
    }

    // MARK: - matching

    func testEmptyCapabilityQueryAcceptsEverything() {
        var q = PackageQuery()
        XCTAssertTrue(q.matches(manifest([])))
        XCTAssertTrue(q.matches(manifest(["fitsio"])))
        q.osFamilies = ["ubuntu"]
        XCTAssertTrue(q.matches(manifest([])))
    }

    func testSingleCapabilityFilter() {
        var q = PackageQuery()
        q.capabilities = ["fitsio"]
        XCTAssertTrue(q.matches(manifest(["fitsio"])))
        XCTAssertTrue(q.matches(manifest(["fitsio", "gpu"])))
        XCTAssertFalse(q.matches(manifest([])))
        XCTAssertFalse(q.matches(manifest(["gpu"])))
    }

    func testMultipleCapabilitiesAreIntersected() {
        // Both must be present (subset semantics, same as the
        // package filters).
        var q = PackageQuery()
        q.capabilities = ["fitsio", "gpu"]
        XCTAssertTrue(q.matches(manifest(["fitsio", "gpu"])))
        XCTAssertTrue(q.matches(manifest(["fitsio", "gpu", "rscript"])))
        XCTAssertFalse(q.matches(manifest(["fitsio"])))
        XCTAssertFalse(q.matches(manifest(["gpu"])))
    }

    // MARK: - vocabulary

    func testCanonicalCapabilityVocabulary() {
        // The probe-emitted strings the parser will accept must
        // include every canonical key — and only canonical keys
        // are documented in the tool schema. Pinning the list
        // here catches drift if a future probe update adds a key
        // without surfacing it through ImageManifest.Capability.
        let canonical = Set(ImageManifest.Capability.all)
        XCTAssertEqual(canonical, [
            "fitsio",
            "photutils-iterative-psf",
            "gpu",
            "python3",
            "conda",
            "rscript",
        ])
    }

    // MARK: - dropping for the chip-disable UI

    func testDroppingCapabilitiesCategoryClearsTheSet() {
        var q = PackageQuery()
        q.capabilities = ["fitsio", "gpu"]
        q.osFamilies = ["ubuntu"]
        let dropped = q.dropping(.capabilities)
        XCTAssertTrue(dropped.capabilities.isEmpty)
        XCTAssertEqual(dropped.osFamilies, ["ubuntu"],
            "dropping one category must not touch other filters")
    }

    // MARK: - isEmpty respects the new field

    func testIsEmptyTrueOnlyWhenAllFiltersIncludingCapabilitiesAreEmpty() {
        var q = PackageQuery()
        XCTAssertTrue(q.isEmpty)
        q.capabilities = ["fitsio"]
        XCTAssertFalse(q.isEmpty,
            "non-empty capabilities must count as filtered, not empty")
    }
}
