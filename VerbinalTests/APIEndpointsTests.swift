// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
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
}
