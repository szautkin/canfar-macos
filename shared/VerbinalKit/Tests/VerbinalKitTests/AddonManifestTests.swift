// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

final class AddonManifestTests: XCTestCase {

    func testRoundTripJSON() throws {
        let manifest = AddonManifest(
            addonID: "com.codebg.Verbinal.addon.notebook",
            displayName: "Notebook",
            subtitle: "Run Jupyter notebooks locally",
            systemIconName: "terminal",
            urlScheme: "verbinal-pi",
            version: "1.0.0",
            minimumHostVersion: "1.2.0",
            capabilities: [
                .viewer(fileTypes: ["public.python-script", "public.json"]),
                .producer
            ],
            authRequirement: .cadcOptional,
            trust: .official(teamID: "A4ABW5VD88", keychainAccessGroup: "A4ABW5VD88.codebg.verbinal.family"),
            appStoreID: 1234567890
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AddonManifest.self, from: data)

        XCTAssertEqual(decoded.addonID, manifest.addonID)
        XCTAssertEqual(decoded.urlScheme, manifest.urlScheme)
        XCTAssertEqual(decoded.authRequirement, .cadcOptional)
        XCTAssertEqual(decoded.trust, manifest.trust)
        XCTAssertEqual(decoded.capabilities.count, 2)
    }

    func testRoundTripPlist() throws {
        let manifest = AddonManifest(
            addonID: "com.example.foo",
            displayName: "Foo",
            subtitle: "Does the foo",
            urlScheme: "foo",
            version: "0.1.0",
            minimumHostVersion: "1.2.0",
            capabilities: [.serviceClient(name: "foo.service")],
            authRequirement: .none,
            trust: .community(homepageURL: URL(string: "https://example.com"))
        )

        let data = try PropertyListEncoder().encode(manifest)
        let decoded = try PropertyListDecoder().decode(AddonManifest.self, from: data)

        XCTAssertEqual(decoded.displayName, "Foo")
        XCTAssertEqual(decoded.authRequirement, AddonAuthRequirement.none)
    }

    func testActivationContextRoundTrip() throws {
        let context = AddonActivationContext.openSkyCoordinate(
            ra: 123.4,
            dec: -12.3,
            radius: 0.01,
            fileURL: URL(fileURLWithPath: "/tmp/example.fits")
        )
        let encoded = try context.encodedForURL()
        let decoded = try AddonActivationContext.decode(from: encoded)
        XCTAssertEqual(decoded, context)
    }

    func testActivationContextBase64URLSafety() throws {
        // JSON payloads with `+`, `/`, or `=` in standard base64 must round-trip
        // through the URL-safe variant the framework uses.
        let context = AddonActivationContext.custom(payload: [
            "weird": "!@#$%^&*()?/+==",
            "unicode": "héllo → world"
        ])
        let encoded = try context.encodedForURL()
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        let decoded = try AddonActivationContext.decode(from: encoded)
        XCTAssertEqual(decoded, context)
    }

    func testSchemaVersionDefaultsToCurrent() {
        let manifest = AddonManifest(
            addonID: "x", displayName: "X", subtitle: "",
            urlScheme: "x", version: "1", minimumHostVersion: "1",
            capabilities: [], authRequirement: .none,
            trust: .community(homepageURL: nil)
        )
        XCTAssertEqual(manifest.schemaVersion, AddonManifest.currentSchemaVersion)
    }
}
