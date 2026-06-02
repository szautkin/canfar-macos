// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

@MainActor
final class AddonBeaconTests: XCTestCase {

    private func makeManifest(urlScheme: String = "verbinal-pi") -> AddonManifest {
        AddonManifest(
            addonID: "com.codebg.Verbinal.addon.test",
            displayName: "Test",
            subtitle: "",
            urlScheme: urlScheme,
            version: "1.0.0",
            minimumHostVersion: "1.0.0",
            capabilities: [],
            authRequirement: .none,
            trust: .community(homepageURL: nil)
        )
    }

    /// Drains the next element from the beacon's activations stream, driving the
    /// supplied side effect (the URL handling) before awaiting so the yield lands
    /// on a continuation an active consumer is buffering.
    private func firstActivation(
        from beacon: AddonBeacon,
        trigger: @escaping @MainActor () -> Void
    ) async -> AddonActivationContext? {
        var iterator = beacon.activations.makeAsyncIterator()
        trigger()
        return await iterator.next()
    }

    func testConstructionDeliversLaunchEmptyForMissingCtx() async {
        let beacon = AddonBeacon(manifest: makeManifest())
        let url = URL(string: "verbinal-pi://activate")!
        let ctx = await firstActivation(from: beacon) {
            beacon.handleIncomingURL(url)
        }
        XCTAssertEqual(ctx, .launchEmpty)
    }

    func testDecodedContextIsDeliveredOnStream() async throws {
        let beacon = AddonBeacon(manifest: makeManifest())
        let expected = AddonActivationContext.openSkyCoordinate(
            ra: 10.0, dec: -20.0, radius: 0.5,
            fileURL: URL(fileURLWithPath: "/tmp/example.fits")
        )
        let encoded = try expected.encodedForURL()
        let url = URL(string: "verbinal-pi://activate?ctx=\(encoded)")!
        let ctx = await firstActivation(from: beacon) {
            beacon.handleIncomingURL(url)
        }
        XCTAssertEqual(ctx, expected)
    }

    func testWrongSchemeIsDroppedWithoutCrashing() async {
        let beacon = AddonBeacon(manifest: makeManifest())
        // Wrong scheme is dropped; finishing then delivers nil rather than a value.
        beacon.handleIncomingURL(URL(string: "other-scheme://activate")!)
        beacon.finish()
        var iterator = beacon.activations.makeAsyncIterator()
        let ctx = await iterator.next()
        XCTAssertNil(ctx)
    }

    func testUnsupportedHostIsDroppedWithoutCrashing() async {
        let beacon = AddonBeacon(manifest: makeManifest())
        beacon.handleIncomingURL(URL(string: "verbinal-pi://something-else?ctx=foo")!)
        beacon.finish()
        var iterator = beacon.activations.makeAsyncIterator()
        let ctx = await iterator.next()
        XCTAssertNil(ctx)
    }

    func testUndecodableCtxIsDroppedWithoutCrashing() async {
        let beacon = AddonBeacon(manifest: makeManifest())
        // `ctx` present but not valid base64-URL JSON → decode fails, dropped.
        beacon.handleIncomingURL(URL(string: "verbinal-pi://activate?ctx=%%%not-base64%%%")!)
        beacon.finish()
        var iterator = beacon.activations.makeAsyncIterator()
        let ctx = await iterator.next()
        XCTAssertNil(ctx)
    }
}
