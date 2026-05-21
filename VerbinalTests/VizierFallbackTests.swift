// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for the VizieR multi-mirror failover. The 2026-05-15 QA
/// report documented that the single hardcoded host
/// `tap.cds.unistra.fr` was DNS-unresolvable for the duration of a
/// 12-hour user session, blocking the entire `vizier_cone_search`
/// workflow. The fix is a four-mirror fallback chain — these tests
/// pin the registry shape, the failover predicate, and the error
/// surface so future changes can't silently regress to "one host or
/// nothing."
final class VizierFallbackTests: XCTestCase {

    // MARK: - Mirror registry

    /// Primary host is the CDS Strasbourg unistra alias — the
    /// canonical VizieR TAP endpoint. Ordering is load-bearing:
    /// the fallback chain assumes try-primary-first semantics.
    func testFirstMirrorIsCDSUnistra() {
        XCTAssertEqual(TAPClient.vizierEndpoints.first?.host, "tap.cds.unistra.fr")
    }

    /// Four mirrors total. Fewer than this and we've lost
    /// geographically-distinct coverage; more and we're likely
    /// trying servers that don't actually mirror the VizieR corpus.
    func testMirrorCount() {
        XCTAssertEqual(TAPClient.vizierEndpoints.count, 4,
                       "expect exactly 4 VizieR TAP mirrors — see TAPClient.vizierEndpoints for rationale")
    }

    /// All four mirror hostnames must be distinct — otherwise the
    /// "rotate to the next host" semantics degenerates.
    func testMirrorHostsAreDistinct() {
        let hosts = Set(TAPClient.vizierEndpoints.map(\.host))
        XCTAssertEqual(hosts.count, TAPClient.vizierEndpoints.count,
                       "mirrors must have distinct hostnames")
    }

    /// Fallback order must include both Strasbourg variants (the
    /// `cds.unistra.fr` and `u-strasbg.fr` zones cover the same
    /// physical CDS infrastructure but live in separate DNS zones —
    /// having both is what gives us resilience against the exact
    /// failure mode the QA report observed). Plus ESAC as the
    /// non-Strasbourg fallback.
    func testMirrorChainContainsStrasbourgAndESAC() {
        let hosts = TAPClient.vizierEndpoints.map(\.host)
        XCTAssertTrue(hosts.contains("tap.cds.unistra.fr"))
        XCTAssertTrue(hosts.contains("tapvizier.u-strasbg.fr"))
        XCTAssertTrue(hosts.contains("tapvizier.esac.esa.int"))
    }

    /// At least one HTTP-only fallback exists for the case where
    /// TLS itself is what's broken (e.g. an expired root CA on
    /// macOS, a corporate MITM). The China-VO mirror is the
    /// documented one.
    func testHasHTTPFallback() {
        let plainHTTP = TAPClient.vizierEndpoints.filter { $0.syncURL.hasPrefix("http://") }
        XCTAssertFalse(plainHTTP.isEmpty,
                       "need at least one HTTP-only mirror as TLS-failure fallback")
    }

    /// Each entry's `syncURL` must end with `/sync` — the TAP-1.1
    /// synchronous endpoint convention. A typo here would surface
    /// as a runtime 404, well after the agent has spent budget
    /// rotating to a "working" mirror.
    func testEverySyncURLEndsWithSync() {
        for endpoint in TAPClient.vizierEndpoints {
            XCTAssertTrue(endpoint.syncURL.hasSuffix("/sync"),
                          "mirror \(endpoint.host) syncURL must end with /sync; got \(endpoint.syncURL)")
        }
    }

    // MARK: - Failover predicate

    /// DNS-level "host could not be found" is the exact failure
    /// mode the QA report observed — it MUST trigger fallover.
    func testURLErrorCannotFindHostIsFailoverWorthy() {
        let err = URLError(.cannotFindHost)
        XCTAssertTrue(TAPClient.isHostFailoverWorthy(err))
    }

    /// "Cannot connect to host" (firewall, refused) is similarly
    /// host-specific.
    func testURLErrorCannotConnectIsFailoverWorthy() {
        XCTAssertTrue(TAPClient.isHostFailoverWorthy(URLError(.cannotConnectToHost)))
    }

    /// Wall-clock timeout on a single host — give the next mirror a
    /// turn.
    func testURLErrorTimedOutIsFailoverWorthy() {
        XCTAssertTrue(TAPClient.isHostFailoverWorthy(URLError(.timedOut)))
    }

    /// 5xx from the server means *this* host is sick — others may
    /// be fine. Failover.
    func testServerErrorIsFailoverWorthy() {
        let err = NetworkError.httpError(503, "service unavailable")
        XCTAssertTrue(TAPClient.isHostFailoverWorthy(err))
    }

    /// 502 (bad gateway) — load balancer can't talk to its
    /// upstream. Same host-specific shape.
    func testBadGatewayIsFailoverWorthy() {
        XCTAssertTrue(TAPClient.isHostFailoverWorthy(NetworkError.httpError(502, "bad gateway")))
    }

    /// 400 (bad request) means the ADQL or catalogue id is wrong.
    /// Every mirror will give the same answer; trying further
    /// hosts just burns budget. Must NOT trigger failover.
    func testBadRequestIsNotFailoverWorthy() {
        XCTAssertFalse(TAPClient.isHostFailoverWorthy(NetworkError.httpError(400, "bad ADQL")))
    }

    /// 404 (catalogue not found) — same logic as 400. The mirror
    /// is fine; the user's request is the problem.
    func testCatalogueNotFoundIsNotFailoverWorthy() {
        XCTAssertFalse(TAPClient.isHostFailoverWorthy(NetworkError.httpError(404, "no such catalogue")))
    }

    /// 401 is auth — VizieR mirrors don't require auth, so this
    /// would be a server config issue, not a host-rotation case.
    func testUnauthorizedIsNotFailoverWorthy() {
        XCTAssertFalse(TAPClient.isHostFailoverWorthy(NetworkError.httpError(401, "unauthorized")))
    }

    /// SearchError messages from `tapQueryAt` wrap the underlying
    /// transport reason as text. The predicate must recognise
    /// transport markers so failover still works when the error
    /// has been re-typed.
    func testSearchErrorWithDNSMarkerIsFailoverWorthy() {
        let err = SearchError.networkError("A server with the specified hostname could not be found.")
        XCTAssertTrue(TAPClient.isHostFailoverWorthy(err))
    }

    func testSearchErrorWithConnectMarkerIsFailoverWorthy() {
        let err = SearchError.networkError("Could not connect to the server.")
        XCTAssertTrue(TAPClient.isHostFailoverWorthy(err))
    }

    func testSearchErrorWithTimeoutMarkerIsFailoverWorthy() {
        let err = SearchError.networkError("The request timed out.")
        XCTAssertTrue(TAPClient.isHostFailoverWorthy(err))
    }

    /// A SearchError wrapping a 4xx (no transport marker) must
    /// NOT trigger failover — the body would be the same on every
    /// mirror.
    func testSearchErrorWithoutTransportMarkerIsNotFailoverWorthy() {
        let err = SearchError.networkError("TAP query failed (HTTP 400): syntax error near 'FORM'")
        XCTAssertFalse(TAPClient.isHostFailoverWorthy(err))
    }

    /// Generic errors with no recognisable shape: assume the safe
    /// "don't rotate" default. Over-rotating wastes budget; under-
    /// rotating just surfaces the original error.
    func testGenericErrorIsNotFailoverWorthy() {
        struct GenericError: Error {}
        XCTAssertFalse(TAPClient.isHostFailoverWorthy(GenericError()))
    }
}
