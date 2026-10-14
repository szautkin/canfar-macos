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
        XCTAssertEqual(controller.activity, .idle, "The spinner must never engage offline")
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
        XCTAssertEqual(controller.activity, .idle)
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

/// Plan 34 A: a 401 signs in again with the stored credentials and retries
/// the request that met it; the sign-in sheet only when that cannot work.
@MainActor
final class RenewalTests: XCTestCase {

    /// CADC, as the mock answers it: one token it accepts at /whoami, one
    /// the data service accepts, and a count of sign-ins.
    private final class CADC: @unchecked Sendable {
        private let lock = NSLock()
        var accepted = "new-token"
        var serviceAccepts = "new-token"
        var password = "pw"
        var unreachable = false
        private(set) var signIns = 0

        func answer(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
            try lock.withLock {
                let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
                let path = request.url?.path ?? ""
                if unreachable, path.hasSuffix("/login") || path.hasSuffix("/whoami") {
                    throw URLError(.notConnectedToInternet)
                }
                func reply(_ status: Int, _ body: String = "") -> (HTTPURLResponse, Data) {
                    (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
                }
                if path.hasSuffix("/login") {
                    signIns += 1
                    let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                    return form.contains("password=\(password)") ? reply(200, "new-token") : reply(401)
                }
                if path.hasSuffix("/whoami") { return bearer == "Bearer \(accepted)" ? reply(200, "alice") : reply(401) }
                if path.contains("/users/") { return reply(200, "<user/>") }
                return bearer == "Bearer \(serviceAccepts)" ? reply(200, "data") : reply(401)
            }
        }
    }

    private var cadc: CADC!
    private var network: NetworkClient!
    private var controller: AuthLifecycleController!
    private var ended = 0
    private let data = "https://ws-uv.canfar.net/arc/nodes/home/alice"

    override func setUp() async throws {
        try await super.setUp()
        KeychainStorage.clearToken()
        cadc = CADC()
        MockURLProtocol.requestHandler = { [cadc] request in try cadc!.answer(request) }
        network = NetworkClient(session: MockURLProtocol.mockSession())
        controller = AuthLifecycleController(authService: AuthService(network: network))
        controller.connectivityProvider = { .satisfied }
        ended = 0
        controller.onSessionExpired = { [weak self] in self?.ended += 1 }
        await network.setUnauthorizedHandler { [controller] attempt in
            await controller!.handleNetworkUnauthorized(attempt)
        }
    }

    override func tearDown() {
        KeychainStorage.clearToken()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// Signed in with `old-token`, with or without a stored password.
    private func signedIn(rememberMe: Bool) async {
        KeychainStorage.saveCredentials(token: "old-token", username: "alice", password: rememberMe ? "pw" : nil)
        await network.setToken("old-token")
        controller.apply(username: "alice", userInfo: nil)
    }

    private func fetchAll(_ count: Int) async -> [Result<String, Error>] {
        await withTaskGroup(of: Result<String, Error>.self) { group in
            for _ in 0..<count {
                group.addTask { [network, data] in
                    do { return .success(try await network!.getText(data)) } catch { return .failure(error) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    func testAnExpiredSignInIsRenewedAndTheRequestsThatMetItAreRetried() async {
        await signedIn(rememberMe: true)
        let results = await fetchAll(5)
        XCTAssertEqual(results.compactMap { try? $0.get() }, Array(repeating: "data", count: 5), "\(results)")
        XCTAssertEqual(cadc.signIns, 1, "five 401s, one sign-in")
        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(KeychainStorage.loadToken().token, "new-token")
        XCTAssertNil(controller.signInReason)
    }

    func testWithNoStoredPasswordTheSheetSaysWhy() async {
        await signedIn(rememberMe: false)
        let results = await fetchAll(3)
        XCTAssertTrue(results.allSatisfy { if case .failure(let error) = $0 { return (error as? NetworkError)?.isUnauthorized == true }; return false })
        XCTAssertEqual(cadc.signIns, 0)
        XCTAssertEqual(ended, 1, "one sheet for every 401")
        XCTAssertFalse(controller.isAuthenticated)
        XCTAssertEqual(controller.signInReason, String(localized: "Your CADC session ended. Sign in to continue."))
    }

    func testARefusedPasswordIsClearedAndTheSheetShows() async {
        await signedIn(rememberMe: true)
        cadc.password = "changed"
        _ = await fetchAll(1)
        XCTAssertEqual(cadc.signIns, 1)
        XCTAssertEqual(ended, 1)
        XCTAssertNil(KeychainStorage.loadCredentials().password, "a password CADC refuses is not kept")
        controller.apply(username: "alice", userInfo: nil)
        XCTAssertNil(controller.signInReason, "signing in clears the reason")
    }

    /// CADC accepts the token; the service refuses it: one fresh sign-in,
    /// one more try.
    func testAServiceRefusingATokenCADCAcceptsGetsOneFreshSignIn() async {
        await signedIn(rememberMe: true)
        cadc.accepted = "old-token"
        cadc.serviceAccepts = "new-token"
        let results = await fetchAll(1)
        XCTAssertEqual(try? results.first?.get(), "data")
        XCTAssertEqual(cadc.signIns, 1)
        XCTAssertEqual(ended, 0)
    }

    /// Without a stored password, one service's refusal fails the request
    /// and leaves the session alone.
    func testAServiceRefusalWithoutAPasswordLeavesTheSession() async {
        await signedIn(rememberMe: false)
        cadc.accepted = "old-token"
        cadc.serviceAccepts = "never"
        let results = await fetchAll(1)
        if case .success = results.first { XCTFail("refused") }
        XCTAssertEqual(cadc.signIns, 0)
        XCTAssertEqual(ended, 0)
        XCTAssertTrue(controller.isAuthenticated)
        XCTAssertEqual(KeychainStorage.loadToken().token, "old-token")
    }

    /// A service that refuses even a fresh sign-in: the request fails after
    /// it — no loop, no second sign-in, the session stays.
    func testAServiceThatRefusesEvenAFreshSignInFailsOnce() async {
        await signedIn(rememberMe: true)
        cadc.accepted = "old-token"
        cadc.serviceAccepts = "never"
        let results = await fetchAll(1)
        if case .success = results.first { XCTFail("refused") }
        XCTAssertEqual(cadc.signIns, 1)
        XCTAssertEqual(ended, 0)
        XCTAssertTrue(controller.isAuthenticated)
    }

    /// CADC out of reach: the request fails, nothing is signed in or
    /// cleared, and the session stays.
    func testOfflineKeepsTheSignInAndSignsInNever() async {
        await signedIn(rememberMe: true)
        cadc.unreachable = true
        let results = await fetchAll(1)
        if case .success = results.first { XCTFail("offline") }
        XCTAssertEqual(cadc.signIns, 0)
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(KeychainStorage.loadCredentials().password, "pw")
        XCTAssertTrue(controller.isAuthenticated)
    }
}

/// Plan 23 A: the sign-in's decisions are said, with their reasons.
@MainActor
final class SignInDecisionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainStorage.clearToken()
    }

    override func tearDown() {
        KeychainStorage.clearToken()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAnExpiredSignInWithNoPasswordEndsAndSaysWhy() async throws {
        KeychainStorage.saveToken("old-token", username: "alice")
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let controller = AuthLifecycleController(authService: AuthService(network: NetworkClient(session: MockURLProtocol.mockSession())))
        controller.connectivityProvider = { .satisfied }
        controller.apply(username: "alice", userInfo: nil)
        let heard = HeardDecisions()
        defer { heard.stop() }
        controller.handleTokenExpired()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(heard.decisions.map(\.rule), [.signInLost])
        XCTAssertTrue(heard.decisions.first?.sentence.contains("no password is stored") == true, "\(heard.decisions)")
    }

    /// What the shared decision log says while a test runs.
    final class HeardDecisions: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Decision] = []
        private var token: UUID?
        init() {
            token = DecisionLog.shared.observers.observe { [weak self] decision in self?.lock.withLock { self?.list.append(decision) } }
        }
        var decisions: [Decision] { lock.withLock { list } }
        func stop() { token.map(DecisionLog.shared.observers.stopObserving) }
    }
}
