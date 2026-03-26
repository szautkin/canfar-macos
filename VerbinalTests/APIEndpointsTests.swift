// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
            "https://ws-uv.canfar.net/ac/users/alice"
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
