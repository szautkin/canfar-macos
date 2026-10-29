// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

final class APIEndpointsTests: XCTestCase {
    private let endpoints = APIEndpoints()

    func testLoginURL() {
        XCTAssertEqual(endpoints.loginURL, "https://cadc-west-01.canfar.net/ac/login")
    }

    func testWhoAmIURL() {
        XCTAssertEqual(endpoints.whoAmIURL, "https://cadc-west-01.canfar.net/ac/whoami")
    }

    func testUserURL() {
        XCTAssertEqual(
            endpoints.userURL("alice"),
            "https://cadc-west-01.canfar.net/ac/users/alice?idType=HTTP&detail=display"
        )
    }

    /// Plan 53 B2: a URL the registry published is used as it is; without
    /// one, the base and its usual path.
    func testAPublishedCapabilityWinsOverTheBaseAndItsPath() {
        let moved = APIEndpoints(capabilityURLs: [
            .login: "https://ac.example.org/a/login",
            .whoami: "https://ac.example.org/a/whoami",
            .users: "https://ac.example.org/a/users",
            .sessions: "https://p.example.org/skaha/v2/session",
            .images: "https://p.example.org/skaha/v2/image",
            .tap: "https://tap.example.org/argus",
            .datalink: "https://dl.example.org/caom2ops/datalink",
            .files: "https://data.example.org/data/pub",
        ])
        XCTAssertEqual(moved.loginURL, "https://ac.example.org/a/login")
        XCTAssertEqual(moved.whoAmIURL, "https://ac.example.org/a/whoami")
        XCTAssertEqual(moved.userURL("alice"), "https://ac.example.org/a/users/alice?idType=HTTP&detail=display")
        XCTAssertEqual(moved.sessionURL("s1"), "https://p.example.org/skaha/v2/session/s1")
        XCTAssertEqual(moved.statsURL, "https://p.example.org/skaha/v2/session?view=stats")
        XCTAssertEqual(moved.desktopAppURL("s1", "a1"), "https://p.example.org/skaha/v2/session/s1/app/a1")
        XCTAssertEqual(moved.imagesURL, "https://p.example.org/skaha/v2/image")
        XCTAssertEqual(moved.contextURL, "https://ws-uv.canfar.net/skaha/v1/context", "not published: the base and its path")
        XCTAssertEqual(moved.tapSyncURL, "https://tap.example.org/argus/sync")
        XCTAssertEqual(moved.datalinkURL, "https://dl.example.org/caom2ops/datalink")
        XCTAssertEqual(moved.dataPubURL(forArtifactURI: "cadc:JCMT/a b.fits")?.absoluteString,
                       "https://data.example.org/data/pub/JCMT/a%20b.fits")
    }

    /// Plan 53 A1: what a service reads is what the source holds now.
    func testLiveEndpointsGiveTheLatest() {
        let live = LiveEndpoints()
        let source: any EndpointsSource = live
        XCTAssertEqual(source.current.loginURL, "https://cadc-west-01.canfar.net/ac/login")
        live.update(APIEndpoints(capabilityURLs: [.login: "https://elsewhere.example.org/ac/login"]))
        XCTAssertEqual(source.current.loginURL, "https://elsewhere.example.org/ac/login")
        XCTAssertEqual(APIEndpoints().current, APIEndpoints(), "a fixed set is its own source")
    }

    func testRegistryURLs() {
        XCTAssertEqual(endpoints.registryBaseURL, "https://cadc-west-01.canfar.net/reg")
        XCTAssertEqual(endpoints.resourceCapsURL, "https://cadc-west-01.canfar.net/reg/resource-caps")
        XCTAssertEqual(endpoints.registryAvailabilityURL, "https://cadc-west-01.canfar.net/reg/availability")
    }

    func testCustomRegistryBaseURLPropagates() {
        let custom = APIEndpoints(registryBaseURL: "https://src.example.org/reg")
        XCTAssertEqual(custom.resourceCapsURL, "https://src.example.org/reg/resource-caps")
        XCTAssertEqual(custom.registryAvailabilityURL, "https://src.example.org/reg/availability")
    }

    func testSessionsURL() {
        XCTAssertEqual(endpoints.sessionsURL, "https://ws-uv.canfar.net/skaha/v1/session")
    }

    func testSessionURL() {
        XCTAssertEqual(
            endpoints.sessionURL("abc123"),
            "https://ws-uv.canfar.net/skaha/v1/session/abc123"
        )
    }

    func testSessionRenewURL() {
        XCTAssertEqual(
            endpoints.sessionRenewURL("abc123"),
            "https://ws-uv.canfar.net/skaha/v1/session/abc123?action=renew"
        )
    }

    func testSessionEventsURL() {
        XCTAssertEqual(
            endpoints.sessionEventsURL("abc123"),
            "https://ws-uv.canfar.net/skaha/v1/session/abc123?view=events"
        )
    }

    func testSessionLogsURL() {
        XCTAssertEqual(
            endpoints.sessionLogsURL("abc123"),
            "https://ws-uv.canfar.net/skaha/v1/session/abc123?view=logs"
        )
    }

    func testStatsURL() {
        XCTAssertEqual(endpoints.statsURL, "https://ws-uv.canfar.net/skaha/v1/session?view=stats")
    }

    func testImagesURL() {
        XCTAssertEqual(endpoints.imagesURL, "https://ws-uv.canfar.net/skaha/v1/image")
    }

    func testContextURL() {
        XCTAssertEqual(endpoints.contextURL, "https://ws-uv.canfar.net/skaha/v1/context")
    }

    func testRepositoryURL() {
        XCTAssertEqual(endpoints.repositoryURL, "https://ws-uv.canfar.net/skaha/v1/repository")
    }

    func testStorageURL() {
        XCTAssertEqual(
            endpoints.storageURL("alice"),
            "https://ws-uv.canfar.net/arc/nodes/home/alice?limit=0"
        )
    }

    // MARK: - dataPubURL

    /// The artefact-URI → direct-download-URL builder is what spares
    /// agents from hand-deriving the CADC data-pub host pattern.
    /// Pinning the wire shape because every change here is a
    /// contract change for `get_data_links` callers.
    func testDataPubURLForJCMTArtifact() {
        XCTAssertEqual(
            endpoints.dataPubURL(forArtifactURI: "cadc:JCMT/scuba2_foo.fits.gz")?.absoluteString,
            "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/data/pub/JCMT/scuba2_foo.fits.gz"
        )
    }

    func testDataPubURLForNestedPath() {
        XCTAssertEqual(
            endpoints.dataPubURL(forArtifactURI: "cadc:CFHT/sub/dir/729989p.fits.fz")?.absoluteString,
            "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/data/pub/CFHT/sub/dir/729989p.fits.fz"
        )
    }

    func testDataPubURLPercentEncodesUnsafeChars() {
        // VOSpace / CADC filenames may legally contain `#` and spaces;
        // they must survive transit through URLSession unchanged.
        let url = endpoints.dataPubURL(forArtifactURI: "cadc:JCMT/odd name#1.fits")?.absoluteString
        XCTAssertEqual(url, "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/data/pub/JCMT/odd%20name%231.fits")
    }

    func testDataPubURLRejectsMissingScheme() {
        XCTAssertNil(endpoints.dataPubURL(forArtifactURI: "no-colon-here"))
    }

    func testDataPubURLRejectsEmptyTail() {
        XCTAssertNil(endpoints.dataPubURL(forArtifactURI: "cadc:"))
    }
}
