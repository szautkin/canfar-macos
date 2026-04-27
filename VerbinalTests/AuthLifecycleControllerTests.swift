// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Behaviour tests for the auth lifecycle slice extracted from AppState.
///
/// These tests use a real `AuthService` backed by `MockURLProtocol` so we
/// exercise the actual `validateToken` / `getUserInfo` paths the controller
/// drives. Keychain reads/writes go to the live process Keychain — but
/// `tearDown` clears them so the suite is hermetic.
@MainActor
final class AuthLifecycleControllerTests: XCTestCase {

    private func makeController(handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)) -> AuthLifecycleController {
        MockURLProtocol.requestHandler = { req in handler(req) }
        let session = MockURLProtocol.mockSession()
        let network = NetworkClient(session: session)
        let endpoints = APIEndpoints()
        let authService = AuthService(network: network, endpoints: endpoints)
        return AuthLifecycleController(authService: authService)
    }

    private func okResponse(_ data: Data) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://ws-cadc.canfar.net/ac/whoami")!
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
    }

    private func errorResponse(_ status: Int) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://ws-cadc.canfar.net/ac/whoami")!
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
    }

    override func setUp() {
        super.setUp()
        KeychainStorage.clearToken()
    }

    override func tearDown() {
        KeychainStorage.clearToken()
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialStateIsLoggedOut() {
        let controller = makeController { _ in self.okResponse(Data()) }
        XCTAssertFalse(controller.isAuthenticated)
        XCTAssertEqual(controller.username, "")
        XCTAssertNil(controller.userInfo)
    }

    // MARK: - validateStoredToken

    func testValidateStoredTokenWithNoTokenSetsLoginPrompt() async {
        let controller = makeController { _ in self.okResponse(Data()) }
        await controller.validateStoredToken()
        XCTAssertEqual(controller.statusMessage, "Please log in")
        XCTAssertFalse(controller.isAuthenticated)
    }

    func testValidateStoredTokenWithValidTokenAuthenticates() async {
        // Seed Keychain with a valid token.
        KeychainStorage.saveToken("valid-token", username: "alice")
        // /whoami returns the username (text), /users/<u> returns XML user info.
        let controller = makeController { request in
            if request.url?.path.contains("/whoami") == true {
                return self.okResponse(Data("alice".utf8))
            }
            // Minimal user XML payload.
            let xml = #"""
            <user xmlns="http://www.opencadc.org/ucs/v1.0">
              <firstName>Alice</firstName>
              <lastName>Astronomer</lastName>
            </user>
            """#
            return self.okResponse(Data(xml.utf8))
        }
        await controller.validateStoredToken()
        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertEqual(controller.username, "alice")
    }

    func testValidateStoredTokenWithExpiredTokenSurfacesPrompt() async {
        KeychainStorage.saveToken("stale-token", username: "alice")
        let controller = makeController { _ in self.errorResponse(401) }
        await controller.validateStoredToken()
        XCTAssertFalse(controller.isAuthenticated)
        XCTAssertTrue(
            controller.statusMessage.lowercased().contains("session expired") ||
            controller.statusMessage.lowercased().contains("log in")
        )
    }

    // MARK: - apply / onAuthenticated

    func testApplyFiresOnAuthenticatedCallback() {
        let controller = makeController { _ in self.okResponse(Data()) }
        var fired = 0
        controller.onAuthenticated = { fired += 1 }
        controller.apply(username: "alice", userInfo: nil)
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertEqual(controller.username, "alice")
    }

    func testApplyUsesDisplayNameWhenAvailable() {
        let controller = makeController { _ in self.okResponse(Data()) }
        let info = UserInfo(
            username: "alice",
            email: "a@example.com",
            firstName: "Alice",
            lastName: "Astronomer",
            institute: "CADC",
            internalID: nil
        )
        controller.apply(username: "alice", userInfo: info)
        XCTAssertTrue(controller.statusMessage.contains("Alice Astronomer"))
    }

    // MARK: - handleTokenExpired

    func testHandleTokenExpiredNoOpWhenNotAuthenticated() {
        let controller = makeController { _ in self.errorResponse(401) }
        var sessionExpiredFires = 0
        controller.onSessionExpired = { sessionExpiredFires += 1 }
        controller.handleTokenExpired()
        XCTAssertEqual(sessionExpiredFires, 0)
    }

    func testHandleTokenExpiredCoalescesConcurrentCalls() async throws {
        let controller = makeController { _ in self.errorResponse(401) }
        controller.apply(username: "alice", userInfo: nil)

        var sessionExpiredFires = 0
        controller.onSessionExpired = { sessionExpiredFires += 1 }

        // Fire a burst of expirations — they should all coalesce onto the
        // single in-flight reauth attempt.
        controller.handleTokenExpired()
        controller.handleTokenExpired()
        controller.handleTokenExpired()

        // Wait for the reauth task to finish. Without a stored token it
        // resolves quickly.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(sessionExpiredFires, 1, "Concurrent 401s must collapse onto one reauth + one prompt")
        XCTAssertFalse(controller.isAuthenticated)
    }

    // MARK: - handleNetworkUnauthorized

    func testHandleNetworkUnauthorizedReturnsTrueWhenTokenStillValid() async {
        KeychainStorage.saveToken("valid-token", username: "alice")
        let controller = makeController { _ in self.okResponse(Data("alice".utf8)) }
        let shouldRetry = await controller.handleNetworkUnauthorized()
        XCTAssertTrue(shouldRetry)
    }

    func testHandleNetworkUnauthorizedReturnsFalseWhenNoToken() async {
        let controller = makeController { _ in self.okResponse(Data()) }
        let shouldRetry = await controller.handleNetworkUnauthorized()
        XCTAssertFalse(shouldRetry)
    }

    func testHandleNetworkUnauthorizedReturnsFalseOnExpiredToken() async {
        KeychainStorage.saveToken("stale-token", username: "alice")
        let controller = makeController { _ in self.errorResponse(401) }
        let shouldRetry = await controller.handleNetworkUnauthorized()
        XCTAssertFalse(shouldRetry)
    }

    // MARK: - clear

    func testClearTearsDownAuthState() async {
        let controller = makeController { _ in self.okResponse(Data()) }
        controller.apply(username: "alice", userInfo: nil)
        XCTAssertTrue(controller.isAuthenticated)

        await controller.clear()

        XCTAssertFalse(controller.isAuthenticated)
        XCTAssertEqual(controller.username, "")
        XCTAssertNil(controller.userInfo)
    }
}
