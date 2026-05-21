// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Coverage for ImageManifest schema v3 — adds `pythonVersion`,
/// `osRelease`, `shells`. Closes the 2026-05-15 QA finding that a
/// `cirada/cutout_core_interactive:latest` image shipping Python
/// 3.6.9 (pre-PEP-563) silently rejected
/// `from __future__ import annotations`, costing one job submission
/// and ~10 minutes of debugging. Surfacing the version pre-launch
/// would have prevented that. These tests pin the schema bump,
/// backward-compatible decode of v2 manifests, and probe-script
/// emission of the new fields.
final class ImageManifestV3Tests: XCTestCase {

    private func makeISO(_ s: String) -> Data {
        Data(s.utf8)
    }

    // MARK: - Schema version pin

    /// Parser must accept v3. Pin to catch the "I bumped the
    /// probe but forgot the parser" failure mode that would
    /// silently reject every fresh probe.
    func testParserAcceptsV3() {
        XCTAssertEqual(ManifestParser.maxSupportedSchemaVersion, 3,
                       "parser must keep pace with probe / inspector schemaVersion bumps")
    }

    func testProbeScriptIsV3() {
        XCTAssertEqual(ProbeScript.schemaVersion, 3)
    }

    func testInspectorScriptIsV3() {
        XCTAssertEqual(InspectorScript.schemaVersion, 3)
    }

    // MARK: - v3 decode

    /// A v3 manifest with the new fields populated round-trips
    /// cleanly. Values must survive decode without loss.
    func testV3ManifestDecodesNewFields() throws {
        let json = """
        {
          "schemaVersion": 3,
          "imageID": "test/image:1.0",
          "contentHash": "sha256:abc",
          "capturedAt": "2026-05-15T12:00:00Z",
          "osFamily": "ubuntu",
          "osVersion": "22.04",
          "osRelease": "Ubuntu 22.04.3 LTS",
          "kernel": "Linux 5.15 aarch64",
          "dpkgPackages": [],
          "rpmPackages": [],
          "apkPackages": [],
          "pythonPackages": [],
          "rPackages": [],
          "condaEnvs": [],
          "capabilities": ["python3", "fitsio"],
          "pythonVersion": "3.11.6",
          "shells": ["bash", "sh", "zsh"]
        }
        """
        let manifest = try ManifestParser.parse(makeISO(json))
        XCTAssertEqual(manifest.schemaVersion, 3)
        XCTAssertEqual(manifest.pythonVersion, "3.11.6")
        XCTAssertEqual(manifest.osRelease, "Ubuntu 22.04.3 LTS")
        XCTAssertEqual(manifest.shells, ["bash", "sh", "zsh"])
    }

    // MARK: - Backward compatibility

    /// A v2 manifest (no new fields) must still decode under the
    /// new schema — the parser falls back to `"unknown"` / `[]`
    /// defaults so existing caches don't need to be wiped after
    /// the user updates the app.
    func testV2ManifestDecodesUnderV3SchemaWithDefaults() throws {
        let json = """
        {
          "schemaVersion": 2,
          "imageID": "test/image:1.0",
          "contentHash": "sha256:abc",
          "capturedAt": "2026-05-15T12:00:00Z",
          "osFamily": "almalinux",
          "osVersion": "9",
          "kernel": "Linux 5.15 x86_64",
          "dpkgPackages": [],
          "rpmPackages": [],
          "apkPackages": [],
          "pythonPackages": [],
          "rPackages": [],
          "condaEnvs": [],
          "capabilities": ["python3"]
        }
        """
        let manifest = try ManifestParser.parse(makeISO(json))
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.pythonVersion, "unknown",
                       "missing v3 field must default to 'unknown', not throw")
        XCTAssertEqual(manifest.osRelease, "unknown")
        XCTAssertEqual(manifest.shells, [],
                       "missing v3 field must default to []")
    }

    /// Even a v1 manifest (which predates capabilities AND v3
    /// fields) must decode. Belt-and-suspenders for very old
    /// caches.
    func testV1ManifestDecodesUnderV3Schema() throws {
        let json = """
        {
          "schemaVersion": 1,
          "imageID": "old/image:1.0",
          "capturedAt": "2025-01-01T00:00:00Z",
          "osFamily": "ubuntu",
          "osVersion": "20.04",
          "kernel": "Linux 5.4 x86_64"
        }
        """
        let manifest = try ManifestParser.parse(makeISO(json))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.pythonVersion, "unknown")
        XCTAssertEqual(manifest.osRelease, "unknown")
        XCTAssertEqual(manifest.shells, [])
        XCTAssertEqual(manifest.capabilities, [])
    }

    // MARK: - Roundtrip

    /// JSON encode → decode preserves every v3 field. Pins that
    /// the synthesised `Codable` conformance keeps the new
    /// fields in its key list.
    func testRoundtripPreservesV3Fields() throws {
        let original = ImageManifest(
            schemaVersion: 3,
            imageID: "test/image:1.0",
            contentHash: "sha256:abc",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            osFamily: "alpine",
            osVersion: "3.18",
            kernel: "Linux 6.1",
            pythonVersion: "3.12.0",
            osRelease: "Alpine Linux v3.18",
            shells: ["sh", "ash"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try ManifestParser.parse(data)
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.pythonVersion, "3.12.0")
        XCTAssertEqual(decoded.osRelease, "Alpine Linux v3.18")
        XCTAssertEqual(decoded.shells, ["sh", "ash"])
    }

    // MARK: - ProbeScript body integrity

    /// The probe body must reference the new field names in the
    /// Python aggregator dict so the emitted JSON actually carries
    /// the new keys. Scraping these as literal substrings catches
    /// the "I bumped schemaVersion but forgot to add the key"
    /// failure mode the 2026-05-14 v2 bump surfaced for
    /// capabilities.
    func testProbeBodyEmitsV3Keys() {
        let body = ProbeScript.body
        XCTAssertTrue(body.contains("\"pythonVersion\":"),
                      "probe body must emit pythonVersion key")
        XCTAssertTrue(body.contains("\"osRelease\":"),
                      "probe body must emit osRelease key")
        XCTAssertTrue(body.contains("\"shells\":"),
                      "probe body must emit shells key")
    }

    /// The bash side stages `python-version.txt` and `shells.txt`
    /// for the aggregator to read. Pin these because removing
    /// them would leave the aggregator reading nothing and the
    /// JSON would carry empty defaults silently.
    func testProbeBodyStagesNewArtifacts() {
        let body = ProbeScript.body
        XCTAssertTrue(body.contains("python-version.txt"),
                      "probe bash must stage python-version.txt")
        XCTAssertTrue(body.contains("shells.txt"),
                      "probe bash must stage shells.txt")
    }

    /// Inspector body emits the v3 keys too — agents that
    /// hit an inspector-mode probe must see the same shape as
    /// the in-target probe path.
    func testInspectorBodyEmitsV3Keys() {
        let body = InspectorScript.body
        XCTAssertTrue(body.contains("\"pythonVersion\""),
                      "inspector body must emit pythonVersion key")
        XCTAssertTrue(body.contains("\"osRelease\""),
                      "inspector body must emit osRelease key")
        XCTAssertTrue(body.contains("\"shells\""),
                      "inspector body must emit shells key")
    }
}
