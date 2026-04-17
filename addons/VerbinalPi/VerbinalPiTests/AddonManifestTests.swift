// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit

/// Guards against Pi's baked-in `VerbinalAddon.plist` drifting from the
/// `AddonManifest` schema the host reads via `AddonRegistry.discoverInstalled()`.
/// A failing test here means a PR likely broke host-side addon discovery.
final class PiManifestTests: XCTestCase {

    /// The plist gets bundled into the test target from VerbinalPi/Resources,
    /// making it addressable via `Bundle(for:).url(forResource:withExtension:)`.
    func testBakedManifestDecodes() throws {
        guard let url = Bundle(for: Self.self)
            .url(forResource: "VerbinalAddon", withExtension: "plist")
            // Fallback to the source file directly — test target isn't wired
            // to copy Pi's Resources yet; read from the workspace path instead.
            ?? sourceManifestURL()
        else {
            throw XCTSkip("VerbinalAddon.plist not reachable from test bundle")
        }

        let data = try Data(contentsOf: url)
        let manifest = try PropertyListDecoder().decode(AddonManifest.self, from: data)

        XCTAssertEqual(manifest.addonID, "com.codebg.Verbinal.addon.notebook")
        XCTAssertEqual(manifest.urlScheme, "verbinal-notebook")
        XCTAssertEqual(manifest.authRequirement, .cadcOptional)
        XCTAssertEqual(manifest.schemaVersion, AddonManifest.currentSchemaVersion)

        // Trust tier should pin to our team and the family keychain group.
        guard case .official(let teamID, let accessGroup) = manifest.trust else {
            XCTFail("Expected .official trust tier, got \(manifest.trust)")
            return
        }
        XCTAssertEqual(teamID, "A4ABW5VD88")
        XCTAssertEqual(accessGroup, "A4ABW5VD88.codebg.verbinal.family")
    }

    /// Source-tree path relative to #file — works when the plist isn't copied
    /// into the test bundle (e.g., swift-test from the package path).
    private func sourceManifestURL() -> URL? {
        let here = URL(fileURLWithPath: #file)
        return here
            .deletingLastPathComponent()       // VerbinalPiTests/
            .deletingLastPathComponent()       // VerbinalPi/
            .appendingPathComponent("VerbinalPi/Resources/VerbinalAddon.plist")
    }

    func testURLSchemeMatchesInfoPlist() throws {
        // Read the addon app's Info.plist at source-tree path and confirm
        // CFBundleURLSchemes contains the scheme the manifest advertises.
        let here = URL(fileURLWithPath: #file)
        let infoPlistURL = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VerbinalPi/Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw XCTSkip("Info.plist not found at expected source path")
        }
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization
            .propertyList(from: data, options: [], format: nil) as? [String: Any]

        let urlTypes = plist?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains("verbinal-notebook"),
                      "Info.plist CFBundleURLSchemes missing 'verbinal-notebook': \(schemes)")
    }
}
