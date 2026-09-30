// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for `get_service_health` — the read-only probe of
/// upstream CADC/VOSpace/Skaha/VizieR reachability. Closes the
/// 2026-05-15 QA finding "A `verbinal-canfar:get_service_health`
/// endpoint feeding a Thought `#blocker` tag would be the right
/// pattern — automated pipelines could pause cleanly rather than
/// retry-and-fail when the VizieR proxy is down."
///
/// Tests pin the canonical endpoint set (so additions/removals
/// are explicit), the status-code → status classification (so
/// 4xx doesn't accidentally flip "down"), and the closure-injection
/// contract (so the tool stays testable without real network).
final class GetServiceHealthTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
    }

    // MARK: - Endpoint registry

    /// The endpoint list MUST include the four high-value
    /// services agents reach for. Listing them explicitly
    /// catches the "I removed one during cleanup" failure
    /// mode.
    func testCanonicalEndpointsCoverCoreServices() {
        let names = Set(GetServiceHealthTool.canonicalEndpoints.map(\.name))
        XCTAssertTrue(names.contains("cadc-tap"))
        XCTAssertTrue(names.contains("vospace"))
        XCTAssertTrue(names.contains("skaha"))
        XCTAssertTrue(names.contains("vizier-cds-unistra"),
                      "primary VizieR mirror must be probed")
    }

    /// Every VizieR mirror in the fallback chain is probed — when one goes
    /// down the person sees at a glance whether the other answers.
    func testCanonicalEndpointsCoverAllVizieRMirrors() {
        let names = Set(GetServiceHealthTool.canonicalEndpoints.map(\.name))
        for mirror in TAPClient.vizierEndpoints {
            XCTAssertTrue(names.contains("vizier-\(mirror.name)"), mirror.host)
        }
    }

    /// Each canonical endpoint has a non-empty host AND url.
    /// Catches the "I added an entry but left a placeholder"
    /// regression.
    func testCanonicalEndpointsAreWellFormed() {
        for endpoint in GetServiceHealthTool.canonicalEndpoints {
            XCTAssertFalse(endpoint.name.isEmpty)
            XCTAssertFalse(endpoint.host.isEmpty)
            XCTAssertNotNil(URL(string: endpoint.url),
                            "endpoint \(endpoint.name): malformed URL \(endpoint.url)")
        }
    }

    /// Endpoint names must be distinct so the output is keyable
    /// by name. Two `cadc-tap` entries would silently shadow
    /// each other in any name-indexed downstream consumer.
    func testEndpointNamesAreDistinct() {
        let names = GetServiceHealthTool.canonicalEndpoints.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    // MARK: - deploymentEndpoints derivation

    /// With CANFAR defaults, the derived probe set must reproduce the
    /// historical canonical URLs exactly — proves the endpoint-settings
    /// refactor changed nothing for a default deployment.
    func testDefaultDeploymentEndpointsMatchHistoricalURLs() {
        let byName = Dictionary(
            uniqueKeysWithValues: GetServiceHealthTool.deploymentEndpoints(for: APIEndpoints())
                .map { ($0.name, $0.url) }
        )
        XCTAssertEqual(byName["cadc-tap"], "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/availability")
        XCTAssertEqual(byName["cadc-resolver"], "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/cadc-target-resolver/availability")
        XCTAssertEqual(byName["vospace"], "https://ws-uv.canfar.net/arc/availability")
        XCTAssertEqual(byName["skaha"], "https://ws-uv.canfar.net/skaha/availability")
        XCTAssertEqual(byName["cadc-registry"], "https://cadc-west-01.canfar.net/reg/availability")
    }

    /// Custom endpoint settings must flow into the probe URLs (the
    /// canonical list would report the wrong backend otherwise).
    func testDeploymentEndpointsFollowCustomEndpoints() {
        let custom = APIEndpoints(
            skahaBaseURL: "https://src.example.org/skaha",
            storageBaseURL: "https://src.example.org/cavern/nodes/home",
            registryBaseURL: "https://src.example.org/reg",
            archiveBaseURL: "https://archive.example.org"
        )
        let byName = Dictionary(
            uniqueKeysWithValues: GetServiceHealthTool.deploymentEndpoints(for: custom)
                .map { ($0.name, $0.url) }
        )
        XCTAssertEqual(byName["skaha"], "https://src.example.org/skaha/availability")
        XCTAssertEqual(byName["vospace"], "https://src.example.org/cavern/availability")
        XCTAssertEqual(byName["cadc-tap"], "https://archive.example.org/argus/availability")
        XCTAssertEqual(byName["cadc-registry"], "https://src.example.org/reg/availability")
        // VizieR mirrors stay global.
        XCTAssertEqual(byName["vizier-cds-unistra"], "https://tapvizier.cds.unistra.fr/TAPVizieR/tap/availability")
    }

    /// The Settings ▸ Endpoints "Test Connections" self-test scopes to the
    /// configured deployment services only: filtering out `vizierMirrors`
    /// (deployment-independent global infrastructure) leaves exactly the five
    /// deployment probes and none of the mirror names. Pins the tab's
    /// probe-scope contract — `Endpoint` being Equatable is what makes the
    /// `!mirrors.contains($0)` filter possible.
    func testDeploymentEndpointsFilterExcludesVizieRMirrors() {
        let mirrors = GetServiceHealthTool.vizierMirrors
        let scoped = GetServiceHealthTool.deploymentEndpoints(for: APIEndpoints())
            .filter { !mirrors.contains($0) }
        let names = Set(scoped.map(\.name))
        XCTAssertEqual(names, ["cadc-auth", "cadc-registry", "cadc-tap", "cadc-resolver", "vospace", "skaha"])
        for mirror in mirrors {
            XCTAssertFalse(names.contains(mirror.name),
                           "self-test scope must exclude VizieR mirror \(mirror.name)")
        }
    }

    // MARK: - classify() pure function

    func test2xxIsOk() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 200, latencyMs: 42
        )
        XCTAssertEqual(s.status, "ok")
        XCTAssertTrue(s.ok)
        XCTAssertEqual(s.latencyMs, 42)
        XCTAssertNil(s.message)
    }

    /// 404 is NOT healthy (Windows 1.3.3 honesty) — probing the wrong
    /// path (e.g. AC base URL) must not report ok.
    func test404IsDegradedNotOk() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 404, latencyMs: 13
        )
        XCTAssertEqual(s.status, "degraded")
        XCTAssertFalse(s.ok)
        XCTAssertTrue(s.message?.contains("404") ?? false)
    }

    func test401IsOkWithMessage() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 401, latencyMs: 18
        )
        XCTAssertEqual(s.status, "ok",
                       "401 means the host is up; we just didn't include credentials on the probe")
        XCTAssertTrue(s.ok)
        XCTAssertTrue(s.message?.contains("401") ?? false)
    }

    func test5xxIsDegraded() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 503, latencyMs: 121
        )
        XCTAssertEqual(s.status, "degraded")
        XCTAssertTrue(s.message?.contains("503") ?? false)
    }

    func test500IsDegraded() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 500, latencyMs: 88
        )
        XCTAssertEqual(s.status, "degraded")
    }

    /// 599 is the upper inclusive bound of 5xx.
    func test599IsDegraded() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 599, latencyMs: 1
        )
        XCTAssertEqual(s.status, "degraded")
    }

    // MARK: - ATS skip (F13)

    /// A plaintext-http endpoint is reported "skipped" (not "down") on
    /// Apple platforms, without a network round-trip — ATS would block it
    /// regardless of the mirror's real health.
    func testPlaintextHTTPProbeIsSkipped() async {
        let httpEndpoint = GetServiceHealthTool.Endpoint(
            name: "vizier-china-vo", host: "vizier.china-vo.org",
            url: "http://vizier.china-vo.org/tap/availability")
        // A session that would fail loudly if actually used — proves the
        // skip returns before any request.
        let output = await GetServiceHealthTool.runCanonicalProbes(
            endpoints: [httpEndpoint], perProbeBudget: 1)
        let service = output.services.first
        XCTAssertEqual(service?.status, "skipped")
        XCTAssertNil(service?.latencyMs)
        XCTAssertTrue(service?.message?.contains("Transport Security") ?? false)
    }

    func testHTTPSProbeIsNotSkipped() async {
        // An https endpoint is NOT short-circuited — it actually probes
        // (and, offline in CI, comes back "down", never "skipped").
        let httpsEndpoint = GetServiceHealthTool.Endpoint(
            name: "vizier-cds-unistra", host: "tap.cds.unistra.fr",
            url: "https://tap.cds.unistra.fr/tap/availability")
        let output = await GetServiceHealthTool.runCanonicalProbes(
            endpoints: [httpsEndpoint], perProbeBudget: 1)
        XCTAssertNotEqual(output.services.first?.status, "skipped")
    }

    // MARK: - Tool surface

    /// The tool must pass through the synthetic probe verbatim —
    /// no rewrapping, no field loss. Wireup layer injects the
    /// real probe; tests inject this shape and read it back.
    func testToolReturnsProbeOutputVerbatim() async throws {
        let synthetic = GetServiceHealthTool.Output(
            services: [
                .init(name: "fake", host: "fake.example", status: "ok", ok: true, latencyMs: 5, message: nil),
                .init(name: "broken", host: "broken.example", status: "down", ok: false, latencyMs: nil, message: "DNS fail"),
            ],
            probeStartedISO: "2026-05-15T12:00:00Z",
            healthyCount: 1
        )
        let tool = GetServiceHealthTool(probe: { synthetic })
        let out = try await tool.handle(EmptyArgs(), context: ctx())
        XCTAssertEqual(out.services.count, 2)
        XCTAssertEqual(out.services.first?.name, "fake")
        XCTAssertEqual(out.services.last?.message, "DNS fail")
        XCTAssertEqual(out.probeStartedISO, "2026-05-15T12:00:00Z")
        XCTAssertEqual(out.healthyCount, 1)
    }

    func testCanonicalEndpointsIncludeAuthWhoAmI() {
        let auth = GetServiceHealthTool.canonicalEndpoints.first { $0.name == "cadc-auth" }
        XCTAssertEqual(auth?.url, APIEndpoints().whoAmIURL)
    }
}
