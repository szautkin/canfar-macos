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
        XCTAssertEqual(endpoints.loginURL, "https://ws-cadc.canfar.net/ac/login")
    }

    func testWhoAmIURL() {
        XCTAssertEqual(endpoints.whoAmIURL, "https://ws-cadc.canfar.net/ac/whoami")
    }

    func testUserURL() {
        XCTAssertEqual(
            endpoints.userURL("alice"),
            "https://ws-cadc.canfar.net/ac/users/alice?idType=HTTP&detail=display"
        )
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
