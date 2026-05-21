// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Phase 3 of the 2026-05-20 UX-audit follow-up: the manifest
// detail sheet lets users verify primary probe data without
// reading on-disk JSON. These tests pin the sheet's pure helpers
// (path resolution, JSON encoding shape) so the reveal-in-Finder
// and copy-as-JSON affordances point at the right file and emit
// the right contents.

import XCTest
@testable import Verbinal

final class ManifestDetailSheetTests: XCTestCase {

    // MARK: - Local-cache path resolution

    /// The "Reveal in Finder" button computes the cached file's
    /// path from the image id via the same `ImageManifest.sanitize`
    /// pipeline the JSONManifestStore uses. Pin that the sanitised
    /// filename has the expected shape so the button doesn't
    /// silently open the wrong path after a future sanitize tweak.
    func testSanitisedFilenameForCanonicalImageID() {
        let id = "images.canfar.net/skaha/astroml:24.07"
        let safe = ImageManifest.sanitize(imageID: id)
        XCTAssertEqual(safe, "images.canfar.net_skaha_astroml_24.07",
                       "sanitisation must replace `/` and `:` with `_`")
    }

    /// Sanitiser must be deterministic across the project's
    /// Codable + persistence layers. If the on-disk file lives at
    /// `<safe>.json` and the sheet computes `<safe>` differently,
    /// the Finder reveal points nowhere. Round-tripping the
    /// canonical example pins the contract.
    func testSanitiseIsIdempotent() {
        let id = "images.canfar.net/cadc/marimo:26.04"
        let once = ImageManifest.sanitize(imageID: id)
        let twice = ImageManifest.sanitize(imageID: once)
        XCTAssertEqual(once, twice,
                       "sanitiser must be idempotent — applying it twice equals once")
    }

    /// JSONManifestStore.defaultDirectory() resolves to a path
    /// under Application Support. Confirm the path ends with the
    /// expected subdirectory structure so a sheet test pointing at
    /// it lands in the same place the cache writes to.
    func testDefaultManifestDirectoryStructure() {
        let dir = JSONManifestStore.defaultDirectory()
        let pathStr = dir.path
        XCTAssertTrue(pathStr.contains("Verbinal"),
                      "directory must live under Verbinal's app support; got \(pathStr)")
        XCTAssertTrue(pathStr.hasSuffix("manifests"),
                      "directory must end in /manifests; got \(pathStr)")
    }

    // MARK: - Codable JSON roundtrip

    /// Copy-as-JSON encodes the manifest with `.prettyPrinted` +
    /// `.sortedKeys` + ISO8601 dates. The encoded bytes must
    /// round-trip back through `ManifestParser.parse` so a user
    /// pasting the clipboard contents into a file and re-loading
    /// gets identical content.
    func testEncodedManifestRoundTrips() throws {
        let original = ImageManifest(
            schemaVersion: 3,
            imageID: "test/image:1.0",
            contentHash: "sha256:abcdef",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            osFamily: "ubuntu",
            osVersion: "22.04",
            kernel: "Linux 5.15 aarch64",
            dpkgPackages: [
                .init(name: "bash", version: "5.2"),
                .init(name: "curl", version: "8.14"),
            ],
            pythonPackages: [
                .init(name: "astropy", version: "6.1.4", source: "pip", env: "")
            ],
            capabilities: ["fitsio", "python3"],
            pythonVersion: "3.11.6",
            osRelease: "Ubuntu 22.04.3 LTS",
            shells: ["bash", "sh"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        // Round-trip via the same parser the cache uses.
        let decoded = try ManifestParser.parse(data)
        XCTAssertEqual(decoded.imageID, original.imageID)
        XCTAssertEqual(decoded.osFamily, original.osFamily)
        XCTAssertEqual(decoded.dpkgPackages.count, 2)
        XCTAssertEqual(decoded.capabilities, ["fitsio", "python3"])
        XCTAssertEqual(decoded.pythonVersion, "3.11.6")
        XCTAssertEqual(decoded.shells, ["bash", "sh"])
    }

    /// Pretty-printed output must contain a newline and the
    /// `sortedKeys` output must list `apkPackages` before
    /// `capabilities` (alphabetical). Pin both invariants so a
    /// future change to JSONEncoder defaults doesn't silently
    /// emit minified or unsorted JSON to the clipboard.
    func testEncodedManifestIsPrettyAndSorted() throws {
        let manifest = ImageManifest(
            schemaVersion: 3,
            imageID: "x:1",
            contentHash: "sha256:x",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            osFamily: "alpine",
            osVersion: "3.18",
            kernel: "Linux"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let s = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(s.contains("\n"), "pretty-printed output must contain newlines")
        // sortedKeys → alphabetical. `apkPackages` < `capabilities`.
        if let apkRange = s.range(of: "\"apkPackages\""),
           let capRange = s.range(of: "\"capabilities\"") {
            XCTAssertLessThan(apkRange.lowerBound, capRange.lowerBound,
                              "sortedKeys must put apkPackages before capabilities")
        } else {
            XCTFail("expected both apkPackages and capabilities keys in output")
        }
    }

    // MARK: - Sheet construction smoke test

    /// Building the sheet with a typical manifest must not crash
    /// (defensive — would catch a future refactor that loses the
    /// `.shells` / `.capabilities` field accessors).
    func testSheetConstructsForTypicalManifest() {
        let manifest = ImageManifest(
            schemaVersion: 3,
            imageID: "images.canfar.net/test/example:1.0",
            contentHash: "sha256:test",
            capturedAt: Date(),
            osFamily: "ubuntu",
            osVersion: "22.04",
            kernel: "Linux",
            dpkgPackages: [.init(name: "bash", version: "5.2")],
            pythonPackages: [.init(name: "numpy", version: "1.26", source: "pip", env: "")],
            capabilities: ["python3"],
            pythonVersion: "3.11.6",
            osRelease: "Ubuntu 22.04.3 LTS",
            shells: ["bash", "sh"]
        )
        _ = ManifestDetailSheet(manifest: manifest)
    }
}
