// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// End-to-end tests of the registry resolution service over
/// `MockURLProtocol`: resource-caps → capabilities → derived endpoint
/// values, plus cache persistence and the never-degrade failure paths.
@MainActor
final class EndpointRegistryServiceTests: XCTestCase {

    private static let suiteName = "test-endpoint-registry"
    private var defaults: UserDefaults!
    private var cacheURL: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("endpoint-registry-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("endpoint-cache.json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent())
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeService(settings: EndpointSettingsService? = nil) -> EndpointRegistryService {
        EndpointRegistryService(
            settings: settings ?? EndpointSettingsService(userDefaults: defaults),
            client: RegistryClient(session: MockURLProtocol.mockSession()),
            cacheURL: cacheURL
        )
    }

    // MARK: - Fixtures

    private func capsXML(root: String, extra: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <vosi:capabilities xmlns:vosi="http://www.ivoa.net/xml/VOSICapabilities/v1.0">
          <capability standardID="ivo://ivoa.net/std/VOSI#availability">
            <interface><accessURL use="full">\(root)/availability</accessURL></interface>
          </capability>
          \(extra)
        </vosi:capabilities>
        """
    }

    /// Wire the mock to a coherent registry: default hosts unless
    /// `archiveHostForData` splits the data service onto another host.
    private func installRegistryHandler(archiveHostForData: String? = nil) {
        let archive = "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca"
        let dataRoot = (archiveHostForData ?? archive) + "/data"
        let resourceCaps = """
        ivo://cadc.nrc.ca/gms = https://reg.test/caps/gms
        ivo://cadc.nrc.ca/skaha = https://reg.test/caps/skaha
        ivo://cadc.nrc.ca/arc = https://reg.test/caps/arc
        ivo://cadc.nrc.ca/argus = https://reg.test/caps/argus
        ivo://cadc.nrc.ca/caom2ops = https://reg.test/caps/caom2ops
        ivo://cadc.nrc.ca/resolver = https://reg.test/caps/resolver
        ivo://cadc.nrc.ca/data = https://reg.test/caps/data
        """
        let nodesExtra = """
        <capability standardID="ivo://ivoa.net/std/VOSpace/v2.0#nodes">
          <interface><accessURL use="base">https://ws-uv.canfar.net/arc/nodes</accessURL></interface>
        </capability>
        """
        let bodies: [String: String] = [
            "/resource-caps": resourceCaps,
            "/caps/gms": capsXML(root: "https://cadc-west-01.canfar.net/ac"),
            "/caps/skaha": capsXML(root: "https://ws-uv.canfar.net/skaha"),
            "/caps/arc": capsXML(root: "https://ws-uv.canfar.net/arc", extra: nodesExtra),
            "/caps/argus": capsXML(root: "\(archive)/argus"),
            "/caps/caom2ops": capsXML(root: "\(archive)/caom2ops"),
            "/caps/resolver": capsXML(root: "\(archive)/cadc-target-resolver"),
            "/caps/data": capsXML(root: dataRoot),
        ]
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            guard let body = bodies.first(where: { path.hasSuffix($0.key) })?.value else {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (resp, Data())
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
    }

    // MARK: - Happy path

    func testRefreshResolvesAppServices() async {
        installRegistryHandler()
        let service = makeService()

        await service.refresh()

        XCTAssertEqual(service.refreshState, .idle)
        let cached = service.cached
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.values[.loginBaseURL], "https://cadc-west-01.canfar.net/ac")
        XCTAssertEqual(cached?.values[.skahaBaseURL], "https://ws-uv.canfar.net/skaha")
        XCTAssertEqual(cached?.values[.storageBaseURL], "https://ws-uv.canfar.net/arc/nodes/home")
        XCTAssertEqual(cached?.values[.archiveBaseURL], "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca")
        XCTAssertTrue(cached?.warnings.isEmpty ?? false)
        // With CANFAR defaults the resolution matches the launch values, and
        // each service's root is where its health is asked.
        var resolvedNow = service.effectiveEndpoints()
        XCTAssertEqual(resolvedNow.availabilityURL(of: "ivo://cadc.nrc.ca/skaha", else: "x"),
                       "https://ws-uv.canfar.net/skaha/availability")
        resolvedNow.serviceRoots = [:]
        XCTAssertEqual(resolvedNow, APIEndpoints())
    }

    func testCacheFileRoundTripsToFreshInstance() async {
        installRegistryHandler()
        let service = makeService()
        await service.refresh()

        MockURLProtocol.requestHandler = { request in
            XCTFail("A fresh instance must read the cache, not the network")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let reloaded = makeService()
        XCTAssertEqual(reloaded.cached?.values[.skahaBaseURL], "https://ws-uv.canfar.net/skaha")
        // Fresh cache → refreshIfStale must not hit the network either.
        await reloaded.refreshIfStale()
    }

    // MARK: - Failure paths never degrade

    func testResourceCapsFailureKeepsPriorCacheAndReportsFailed() async {
        installRegistryHandler()
        let service = makeService()
        await service.refresh()
        let before = service.cached
        XCTAssertNotNil(before)

        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await service.refresh()

        XCTAssertEqual(service.cached, before, "A failed refresh must keep the previous cache")
        if case .failed = service.refreshState {} else {
            XCTFail("Expected .failed, got \(service.refreshState)")
        }
    }

    func testGarbageResourceCapsReportsFailedWithoutCache() async {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("<html>not a resource-caps file</html>".utf8))
        }
        let service = makeService()
        await service.refresh()

        XCTAssertNil(service.cached)
        if case .failed = service.refreshState {} else {
            XCTFail("Expected .failed, got \(service.refreshState)")
        }
        // Effective endpoints fall back to pure defaults.
        XCTAssertEqual(service.effectiveEndpoints(), APIEndpoints())
    }

    func testArchiveHostDisagreementLeavesArchiveUnresolved() async {
        installRegistryHandler(archiveHostForData: "https://elsewhere.example.org")
        let service = makeService()

        await service.refresh()

        XCTAssertNil(service.cached?.values[.archiveBaseURL], "Split archive deployment cannot map onto one base URL")
        XCTAssertFalse(service.cached?.warnings.isEmpty ?? true)
        XCTAssertEqual(service.effectiveEndpoints().archiveBaseURL, APIEndpoints().archiveBaseURL)
        // The other fields still resolve normally.
        XCTAssertEqual(service.cached?.values[.skahaBaseURL], "https://ws-uv.canfar.net/skaha")
    }

    // MARK: - Live answers + precedence

    /// Plan 53 C4: every answer is told, so the app applies it live.
    func testEveryAnswerIsToldSoItAppliesLive() async {
        installRegistryHandler()
        let service = makeService()
        var told = 0
        service.onChange = { told += 1 }
        await service.refresh()
        XCTAssertEqual(told, 1)
    }

    /// Plan 53 B: each URL is the one its service publishes, and an override
    /// sets aside what its service published, not the others'.
    func testPublishedCapabilitiesBecomeTheURLsAndAnOverrideSetsItsOwnAside() async {
        let gms = capsXML(root: "https://moved.example.org/ac", extra: """
        <capability standardID="ivo://ivoa.net/std/UMS#login-0.1"><interface><accessURL use="full">https://moved.example.org/ac/login</accessURL></interface></capability>
        <capability standardID="ivo://ivoa.net/std/UMS#whoami-0.1"><interface><accessURL use="full">https://moved.example.org/ac/whoami/</accessURL></interface></capability>
        """)
        let skaha = capsXML(root: "https://ws-uv.canfar.net/skaha", extra: """
        <capability standardID="http://www.opencadc.org/std/platform#session-1"><interface><accessURL use="base">https://ws-uv.canfar.net/skaha/v2/session</accessURL></interface></capability>
        """)
        let ums = capsXML(root: "https://moved.example.org/ac")
        let bodies = ["/resource-caps": """
        ivo://cadc.nrc.ca/gms = https://reg.test/caps/gms
        ivo://cadc.nrc.ca/ums = https://reg.test/caps/ums
        ivo://cadc.nrc.ca/skaha = https://reg.test/caps/skaha
        """, "/caps/gms": gms, "/caps/ums": ums, "/caps/skaha": skaha]
        MockURLProtocol.requestHandler = { request in
            let body = bodies.first { (request.url?.path ?? "").hasSuffix($0.key) }?.value
            return (HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!,
                    Data((body ?? "").utf8))
        }
        let settings = EndpointSettingsService(userDefaults: defaults)
        let service = makeService(settings: settings)
        await service.refresh()

        var endpoints = service.effectiveEndpoints()
        XCTAssertEqual(endpoints.loginURL, "https://moved.example.org/ac/login")
        XCTAssertEqual(endpoints.whoAmIURL, "https://moved.example.org/ac/whoami", "a trailing slash is dropped")
        XCTAssertEqual(endpoints.acBaseURL, "https://moved.example.org/ac", "the account service from ums")
        XCTAssertEqual(endpoints.sessionURL("s1"), "https://ws-uv.canfar.net/skaha/v2/session/s1")

        settings.setOverride("https://pinned.example.org/skaha", for: .skahaBaseURL)
        endpoints = service.effectiveEndpoints()
        XCTAssertEqual(endpoints.sessionsURL, "https://pinned.example.org/skaha/v1/session", "the override wins")
        XCTAssertEqual(endpoints.loginURL, "https://moved.example.org/ac/login", "the others stay as published")
    }

    /// Plan 53 C3: a service in trouble asks the registry again, at most once in the window.
    func testAServiceInTroubleAsksAgainAtMostOnceInTheWindow() async {
        installRegistryHandler()
        let service = makeService()
        var told = 0
        service.onChange = { told += 1 }
        let now = Date()
        await service.serviceInTrouble(now: now)
        await service.serviceInTrouble(now: now.addingTimeInterval(60))
        XCTAssertEqual(told, 1, "once in the window")
        await service.serviceInTrouble(now: now.addingTimeInterval(EndpointRegistryService.troubleAskEvery + 1))
        XCTAssertEqual(told, 2)
    }

    /// Plan 53 C4: what moved, as the decision log says it.
    func testWhatMovedIsSaidPlainly() {
        let before = APIEndpoints(loginBaseURL: "https://ws-cadc.canfar.net/ac")
        let after = APIEndpoints()
        XCTAssertEqual(EndpointMoves.between(before, after),
                       ["Sign-in is now reached at https://cadc-west-01.canfar.net/ac/login, not https://ws-cadc.canfar.net/ac/login."])
        XCTAssertEqual(EndpointMoves.between(after, after), [])
    }

    func testOverrideBeatsResolvedValue() async {
        installRegistryHandler()
        let settings = EndpointSettingsService(userDefaults: defaults)
        settings.setOverride("https://pinned.example.org/skaha", for: .skahaBaseURL)
        let service = makeService(settings: settings)

        await service.refresh()

        XCTAssertEqual(service.effectiveEndpoints().skahaBaseURL, "https://pinned.example.org/skaha")
        XCTAssertEqual(service.source(for: .skahaBaseURL), .override)
        XCTAssertEqual(service.source(for: .loginBaseURL), .resolved)
    }

    func testCacheFromDifferentRegistryDoesNotApply() async {
        installRegistryHandler()
        let service = makeService()
        await service.refresh()
        XCTAssertEqual(service.source(for: .skahaBaseURL), .resolved)

        // Point the app at another registry: the old cache must stop applying.
        let settings = EndpointSettingsService(userDefaults: defaults)
        settings.setOverride("https://other-registry.example.org/reg", for: .registryBaseURL)
        let reloaded = makeService(settings: settings)

        XCTAssertEqual(reloaded.source(for: .skahaBaseURL), .defaultValue)
        XCTAssertEqual(reloaded.effectiveEndpoints().skahaBaseURL, APIEndpoints().skahaBaseURL)
    }
}
