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

    /// The two offline status messages the controller can set, routed through
    /// the catalog so the asserts hold in any host locale (the app's language
    /// override applies to the hosted test runner too).
    private let offlineMessages = [
        String(localized: "You're offline. Verbinal will sign you in when the connection returns."),
        String(localized: "You appear to be offline. Verbinal will reconnect automatically."),
    ]

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
        XCTAssertEqual(controller.statusMessage, String(localized: "Please log in"))
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
        // Status messages are localized — match against the catalog-routed
        // values instead of English substrings.
        let prompts = [
            String(localized: "Session expired. Please log in again."),
            String(localized: "Please log in"),
        ]
        XCTAssertTrue(prompts.contains(controller.statusMessage),
                      "Expected a login prompt, got '\(controller.statusMessage)'")
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
        // Re-apply while already authenticated must not re-fire.
        controller.apply(username: "alice", userInfo: nil)
        XCTAssertEqual(fired, 1)
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

    func testHandleTokenExpiredSuccessfulReauthKeepsAuthenticated() async throws {
        KeychainStorage.saveToken("valid-token", username: "alice")
        let controller = makeController { request in
            if request.url?.path.contains("/whoami") == true {
                return self.okResponse(Data("alice".utf8))
            }
            return self.okResponse(Data())
        }
        controller.connectivityProvider = { .satisfied }
        controller.apply(username: "alice", userInfo: nil)

        var sessionExpiredFires = 0
        var authFires = 0
        controller.onSessionExpired = { sessionExpiredFires += 1 }
        controller.onAuthenticated = { authFires += 1 }

        controller.handleTokenExpired()
        // Still authenticated during the in-flight silent reauth.
        XCTAssertTrue(controller.isAuthenticated)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertEqual(sessionExpiredFires, 0)
        XCTAssertEqual(authFires, 0, "Silent reauth must not re-fire onAuthenticated")
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

    // MARK: - Offline gating / connectivity retry

    func testValidateStoredTokenOfflineShortCircuitsWithoutNetworkCall() async {
        KeychainStorage.saveToken("valid-token", username: "alice")
        let controller = makeController { _ in
            XCTFail("No network call expected while definitely offline")
            return self.errorResponse(500)
        }
        controller.connectivityProvider = { .unsatisfied }

        await controller.validateStoredToken()

        XCTAssertTrue(controller.awaitingConnectivity)
        XCTAssertFalse(controller.isLoading, "The spinner must never engage offline")
        XCTAssertFalse(controller.isAuthenticated)
        XCTAssertTrue(offlineMessages.contains(controller.statusMessage),
                      "Expected an offline status, got '\(controller.statusMessage)'")
    }

    func testUnknownConnectivityStillAttemptsValidation() async {
        // Regression pin: the default (unwired) provider must not change
        // online behavior — .unknown proceeds with the network call.
        KeychainStorage.saveToken("valid-token", username: "alice")
        var sawRequest = false
        let controller = makeController { request in
            if request.url?.path.contains("/whoami") == true {
                sawRequest = true
                return self.okResponse(Data("alice".utf8))
            }
            return self.okResponse(Data())
        }

        await controller.validateStoredToken()

        XCTAssertTrue(sawRequest)
        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertFalse(controller.awaitingConnectivity)
    }

    func testNetworkErrorArmsAwaitingConnectivity() async {
        KeychainStorage.saveToken("valid-token", username: "alice")
        let controller = makeController { _ in self.okResponse(Data()) }
        controller.connectivityProvider = { .satisfied }
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }

        await controller.validateStoredToken()

        XCTAssertTrue(controller.awaitingConnectivity)
        XCTAssertFalse(controller.isAuthenticated)
        XCTAssertFalse(controller.isLoading)
    }

    func testRetryAfterConnectivityRestoredAuthenticates() async {
        KeychainStorage.saveToken("valid-token", username: "alice")
        var connectivity = NetworkPathMonitor.Connectivity.unsatisfied
        let controller = makeController { request in
            if request.url?.path.contains("/whoami") == true {
                return self.okResponse(Data("alice".utf8))
            }
            return self.okResponse(Data())
        }
        controller.connectivityProvider = { connectivity }

        await controller.validateStoredToken()
        XCTAssertTrue(controller.awaitingConnectivity)

        connectivity = .satisfied
        await controller.retryValidationIfConnectivityRestored()

        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertFalse(controller.awaitingConnectivity)
    }

    func testRetryIsNoOpWhenNotAwaitingConnectivity() async {
        let controller = makeController { _ in
            XCTFail("Retry must be a no-op when nothing was deferred")
            return self.errorResponse(500)
        }
        controller.connectivityProvider = { .satisfied }
        await controller.retryValidationIfConnectivityRestored()
        XCTAssertFalse(controller.isAuthenticated)
    }

    func testRetryIsNoOpWhileStillUnsatisfied() async {
        KeychainStorage.saveToken("valid-token", username: "alice")
        let controller = makeController { _ in
            XCTFail("Retry must not fire while the path is still down")
            return self.errorResponse(500)
        }
        controller.connectivityProvider = { .unsatisfied }

        await controller.validateStoredToken()   // arms awaitingConnectivity
        await controller.retryValidationIfConnectivityRestored()

        XCTAssertTrue(controller.awaitingConnectivity, "Deferred sign-in must stay armed")
    }

    func testRetryIsNoOpWhenAlreadyAuthenticated() async {
        let controller = makeController { _ in
            XCTFail("Retry must be a no-op for an authenticated session")
            return self.errorResponse(500)
        }
        controller.connectivityProvider = { .satisfied }
        controller.apply(username: "alice", userInfo: nil)

        await controller.retryValidationIfConnectivityRestored()

        XCTAssertTrue(controller.isAuthenticated)
    }

    func testHandleTokenExpiredOfflineDoesNotFireSessionExpired() async throws {
        KeychainStorage.saveToken("valid-token", username: "alice")
        let controller = makeController { _ in
            XCTFail("No network call expected while definitely offline")
            return self.errorResponse(500)
        }
        controller.connectivityProvider = { .unsatisfied }
        controller.apply(username: "alice", userInfo: nil)

        var sessionExpiredFires = 0
        controller.onSessionExpired = { sessionExpiredFires += 1 }

        controller.handleTokenExpired()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(sessionExpiredFires, 0, "Offline must not masquerade as session expiry")
        XCTAssertTrue(controller.isAuthenticated, "Mid-session offline must keep the live session")
        XCTAssertTrue(controller.awaitingConnectivity)
        let (token, _) = KeychainStorage.loadToken()
        XCTAssertEqual(token, "valid-token", "Offline must not clear the stored token")
        XCTAssertTrue(offlineMessages.contains(controller.statusMessage),
                      "Expected an offline status, got '\(controller.statusMessage)'")
    }

    func testRetryAfterMidSessionOfflineSoftValidates() async throws {
        KeychainStorage.saveToken("valid-token", username: "alice")
        var connectivity = NetworkPathMonitor.Connectivity.unsatisfied
        let controller = makeController { request in
            if request.url?.path.contains("/whoami") == true {
                return self.okResponse(Data("alice".utf8))
            }
            return self.okResponse(Data())
        }
        controller.connectivityProvider = { connectivity }
        controller.apply(username: "alice", userInfo: nil)

        controller.handleTokenExpired()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(controller.awaitingConnectivity)
        XCTAssertTrue(controller.isAuthenticated)

        connectivity = .satisfied
        await controller.retryValidationIfConnectivityRestored()

        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertFalse(controller.awaitingConnectivity)
    }

    func testHandleTokenExpiredExpiredTokenStillFiresSessionExpired() async throws {
        // Regression guard: real expiry (401 from /whoami, no stored password)
        // must still surface the login sheet even with connectivity wired.
        KeychainStorage.saveToken("stale-token", username: "alice")
        let controller = makeController { _ in self.errorResponse(401) }
        controller.connectivityProvider = { .satisfied }
        controller.apply(username: "alice", userInfo: nil)

        var sessionExpiredFires = 0
        controller.onSessionExpired = { sessionExpiredFires += 1 }

        controller.handleTokenExpired()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(sessionExpiredFires, 1)
        XCTAssertFalse(controller.isAuthenticated)
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
