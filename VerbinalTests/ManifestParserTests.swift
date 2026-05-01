// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ManifestParserTests: XCTestCase {

    // MARK: - Happy paths

    func testParsesUbuntuCondaManifest() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "imageID": "images.canfar.net/skaha/astroml:24.07",
          "contentHash": "sha256:abc123",
          "capturedAt": "2026-04-30T18:42:11Z",
          "osFamily": "ubuntu",
          "osVersion": "22.04",
          "kernel": "Linux 5.15.0-1062-aws x86_64",
          "dpkgPackages": [
            {"name":"libc6","version":"2.35-0ubuntu3.4"},
            {"name":"openssh-client","version":"1:8.9p1-3ubuntu0.6"}
          ],
          "rpmPackages": [],
          "apkPackages": [],
          "pythonPackages": [
            {"name":"astropy","version":"6.0.1","source":"conda","env":"base"},
            {"name":"numpy","version":"1.26.4","source":"conda","env":"base"}
          ],
          "rPackages": [],
          "condaEnvs": [
            {
              "name": "base",
              "prefix": "/opt/conda",
              "packages": [
                {"name":"astropy","version":"6.0.1","source":"conda","env":"base"},
                {"name":"numpy","version":"1.26.4","source":"conda","env":"base"}
              ]
            }
          ]
        }
        """#

        let manifest = try ManifestParser.parse(json)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.imageID, "images.canfar.net/skaha/astroml:24.07")
        XCTAssertEqual(manifest.contentHash, "sha256:abc123")
        XCTAssertEqual(manifest.osFamily, "ubuntu")
        XCTAssertEqual(manifest.osVersion, "22.04")
        XCTAssertEqual(manifest.dpkgPackages.count, 2)
        XCTAssertEqual(manifest.dpkgPackages[0].name, "libc6")
        XCTAssertEqual(manifest.pythonPackages.count, 2)
        XCTAssertEqual(manifest.condaEnvs.count, 1)
        XCTAssertEqual(manifest.condaEnvs[0].packages.count, 2)
        XCTAssertNil(manifest.probeNotes)
    }

    func testParsesAlmalinuxRpmManifest() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "imageID": "images.canfar.net/cadc/casa:6.5",
          "contentHash": "sha256:def456",
          "capturedAt": "2026-04-30T19:00:00Z",
          "osFamily": "almalinux",
          "osVersion": "9",
          "kernel": "Linux 4.18.0-477.el8 x86_64",
          "dpkgPackages": [],
          "rpmPackages": [
            {"name":"openssl","version":"3.0.7-25.el9"},
            {"name":"glibc","version":"2.34-83.el9"}
          ],
          "apkPackages": [],
          "pythonPackages": [],
          "rPackages": [],
          "condaEnvs": []
        }
        """#

        let manifest = try ManifestParser.parse(json)
        XCTAssertEqual(manifest.osFamily, "almalinux")
        XCTAssertEqual(manifest.rpmPackages.count, 2)
        XCTAssertTrue(manifest.dpkgPackages.isEmpty)
    }

    func testParsesAlpineApkManifest() throws {
        let json = #"""
        {
          "schemaVersion": 1,
          "imageID": "images.canfar.net/skaha/minimal:latest",
          "contentHash": "sha256:fed789",
          "capturedAt": "2026-04-30T19:30:00Z",
          "osFamily": "alpine",
          "osVersion": "3.18",
          "kernel": "Linux 5.15.0 x86_64",
          "dpkgPackages": [],
          "rpmPackages": [],
          "apkPackages": [
            {"name":"musl","version":"1.2.4-r1"},
            {"name":"busybox","version":"1.36.1-r5"}
          ],
          "pythonPackages": [],
          "rPackages": [],
          "condaEnvs": []
        }
        """#

        let manifest = try ManifestParser.parse(json)
        XCTAssertEqual(manifest.apkPackages.count, 2)
        XCTAssertEqual(manifest.apkPackages[0].version, "1.2.4-r1")
    }

    func testParsesEmptyManifestWithNotes() throws {
        // Probe ran successfully but the image has none of dpkg/rpm/apk/pip.
        // This is success, not failure — the manifest is just empty.
        let json = #"""
        {
          "schemaVersion": 1,
          "imageID": "images.canfar.net/skaha/scratch:edge",
          "contentHash": "sha256:none",
          "capturedAt": "2026-04-30T20:00:00Z",
          "osFamily": "unknown",
          "osVersion": "unknown",
          "kernel": "Linux 5.15.0 x86_64",
          "dpkgPackages": [],
          "rpmPackages": [],
          "apkPackages": [],
          "pythonPackages": [],
          "rPackages": [],
          "condaEnvs": [],
          "probeNotes": "image lacks dpkg/rpm/apk and pip — minimal manifest"
        }
        """#

        let manifest = try ManifestParser.parse(json)
        XCTAssertEqual(manifest.probeNotes, "image lacks dpkg/rpm/apk and pip — minimal manifest")
        XCTAssertTrue(manifest.dpkgPackages.isEmpty)
        XCTAssertTrue(manifest.pythonPackages.isEmpty)
    }

    // MARK: - Forward-compatibility

    func testToleratesMissingOptionalFields() throws {
        // A future probe drops a section (or the cache holds an old shape).
        // The decoder must default missing arrays to [] without throwing.
        let json = #"""
        {
          "schemaVersion": 1,
          "imageID": "test:1",
          "capturedAt": "2026-04-30T20:00:00Z",
          "osFamily": "ubuntu",
          "osVersion": "22.04",
          "kernel": "Linux"
        }
        """#

        let manifest = try ManifestParser.parse(json)
        XCTAssertEqual(manifest.contentHash, "sha256:none")
        XCTAssertTrue(manifest.dpkgPackages.isEmpty)
        XCTAssertTrue(manifest.pythonPackages.isEmpty)
        XCTAssertTrue(manifest.condaEnvs.isEmpty)
    }

    // MARK: - Error paths

    func testEmptyDataThrowsEmpty() {
        XCTAssertThrowsError(try ManifestParser.parse(Data())) { error in
            XCTAssertEqual(error as? ManifestParser.ParseError, .empty)
        }
    }

    func testMalformedJSONThrowsMalformed() {
        let bad = Data("{not json".utf8)
        XCTAssertThrowsError(try ManifestParser.parse(bad)) { error in
            guard case .malformed = error as? ManifestParser.ParseError else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func testTypeMismatchThrowsMalformed() {
        let json = #"""
        {
          "schemaVersion": 1,
          "imageID": "test:1",
          "capturedAt": "2026-04-30T20:00:00Z",
          "osFamily": "ubuntu",
          "osVersion": "22.04",
          "kernel": "Linux",
          "dpkgPackages": "not-an-array"
        }
        """#
        XCTAssertThrowsError(try ManifestParser.parse(json)) { error in
            guard case .malformed = error as? ManifestParser.ParseError else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func testFutureSchemaVersionRejected() {
        let json = #"""
        {
          "schemaVersion": 99,
          "imageID": "test:1",
          "capturedAt": "2026-04-30T20:00:00Z",
          "osFamily": "ubuntu",
          "osVersion": "22.04",
          "kernel": "Linux"
        }
        """#
        XCTAssertThrowsError(try ManifestParser.parse(json)) { error in
            XCTAssertEqual(error as? ManifestParser.ParseError, .unknownSchema(99))
        }
    }

    // MARK: - Sanitization

    func testImageIDSanitizationStripsFilesystemUnsafeChars() {
        XCTAssertEqual(
            ImageManifest.sanitize(imageID: "images.canfar.net/skaha/astroml:24.07"),
            "images.canfar.net_skaha_astroml_24.07"
        )
        XCTAssertEqual(
            ImageManifest.sanitize(imageID: "images.canfar.net/x/y:1?2*3"),
            "images.canfar.net_x_y_1_2_3"
        )
        XCTAssertEqual(
            ImageManifest.sanitize(imageID: "simple"),
            "simple"
        )
    }

    // MARK: - Round-trip

    func testManifestRoundTripsThroughCodable() throws {
        let original = ImageManifest(
            schemaVersion: 1,
            imageID: "images.canfar.net/skaha/test:1.0",
            contentHash: "sha256:roundtrip",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            osFamily: "ubuntu",
            osVersion: "22.04",
            kernel: "Linux",
            dpkgPackages: [.init(name: "a", version: "1")],
            pythonPackages: [.init(name: "astropy", version: "6", source: "pip", env: "base")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoded = try ManifestParser.parse(data)
        XCTAssertEqual(decoded.imageID, original.imageID)
        XCTAssertEqual(decoded.dpkgPackages, original.dpkgPackages)
        XCTAssertEqual(decoded.pythonPackages, original.pythonPackages)
    }

    // MARK: - Probe script integrity

    func testProbeScriptSchemaVersionMatchesParser() {
        // If someone bumps the probe's schemaVersion without updating
        // the parser's max, the cache layer would silently drop fresh
        // discoveries. Pin them together.
        XCTAssertEqual(ProbeScript.schemaVersion, ManifestParser.maxSupportedSchemaVersion)
    }

    func testProbeScriptHashIsStableAcrossInvocations() {
        // The hash drives the on-VOSpace upload filename
        // (probe-<hash>.sh). It must be deterministic across runs of
        // the same Verbinal binary or we'd re-upload the script every
        // launch.
        XCTAssertEqual(ProbeScript.scriptHash, ProbeScript.scriptHash)
        XCTAssertFalse(ProbeScript.scriptHash.isEmpty)
        XCTAssertEqual(ProbeScript.scriptHash.count, 12)
        XCTAssertEqual(ProbeScript.uploadFilename, "probe-\(ProbeScript.scriptHash).sh")
    }

    func testProbeScriptBodyEmbedsRequiredEnvAndOutputPath() {
        // Spot-check the bash entry references the contract bits the
        // launcher relies on: IMAGE_ID env, $HOME/.verbinal/manifests/
        // output, atomic .partial → final move.
        let body = ProbeScript.body
        XCTAssertTrue(body.contains("IMAGE_ID"), "probe must read IMAGE_ID from env")
        XCTAssertTrue(body.contains(".verbinal/manifests"))
        XCTAssertTrue(body.contains("mv \"$TMP\" \"$OUT\""), "atomic publish step")
        XCTAssertTrue(body.contains("schemaVersion"))
    }
}
