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

    /// All four VizieR mirrors named in the fallback chain must
    /// be probed — when CDS Strasbourg goes down (the QA's
    /// failure scenario) the user needs to see at a glance
    /// which of the other three are reachable.
    func testCanonicalEndpointsCoverAllVizieRMirrors() {
        let names = Set(GetServiceHealthTool.canonicalEndpoints.map(\.name))
        XCTAssertTrue(names.contains("vizier-cds-unistra"))
        XCTAssertTrue(names.contains("vizier-cds-u-strasbg"))
        XCTAssertTrue(names.contains("vizier-esac"))
        XCTAssertTrue(names.contains("vizier-china-vo"))
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

    // MARK: - classify() pure function

    func test2xxIsOk() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 200, latencyMs: 42
        )
        XCTAssertEqual(s.status, "ok")
        XCTAssertEqual(s.latencyMs, 42)
        XCTAssertNil(s.message)
    }

    /// 4xx ⇒ "ok" — host reachable, just no `/availability`
    /// endpoint implemented (or it needs auth). The agent
    /// shouldn't treat 404 on the probe path as "the service
    /// is down."
    func test4xxIsOkWithMessage() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 404, latencyMs: 13
        )
        XCTAssertEqual(s.status, "ok",
                       "4xx must read as host-reachable; the /availability endpoint just isn't implemented")
        XCTAssertNotNil(s.message)
        XCTAssertTrue(s.message?.contains("404") ?? false)
    }

    func test401IsOkWithMessage() {
        let s = GetServiceHealthTool.classify(
            name: "n", host: "h", statusCode: 401, latencyMs: 18
        )
        XCTAssertEqual(s.status, "ok",
                       "401 means the host is up; we just didn't include credentials on the probe")
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

    // MARK: - Tool surface

    /// The tool must pass through the synthetic probe verbatim —
    /// no rewrapping, no field loss. Wireup layer injects the
    /// real probe; tests inject this shape and read it back.
    func testToolReturnsProbeOutputVerbatim() async throws {
        let synthetic = GetServiceHealthTool.Output(
            services: [
                .init(name: "fake", host: "fake.example", status: "ok", latencyMs: 5, message: nil),
                .init(name: "broken", host: "broken.example", status: "down", latencyMs: nil, message: "DNS fail"),
            ],
            probeStartedISO: "2026-05-15T12:00:00Z"
        )
        let tool = GetServiceHealthTool(probe: { synthetic })
        let out = try await tool.handle(EmptyArgs(), context: ctx())
        XCTAssertEqual(out.services.count, 2)
        XCTAssertEqual(out.services.first?.name, "fake")
        XCTAssertEqual(out.services.last?.message, "DNS fail")
        XCTAssertEqual(out.probeStartedISO, "2026-05-15T12:00:00Z")
    }
}
