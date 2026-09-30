// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

final class AuthServiceTests: XCTestCase {

    private func makeService() -> AuthService {
        AuthService(network: NetworkClient(session: MockURLProtocol.mockSession()))
    }

    // MARK: - Token Validation

    func testValidateTokenReturnsValidOnSuccess() async {
        let service = makeService()

        MockURLProtocol.requestHandler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("alice".utf8))
        }

        let result = await service.validateToken("good-token")
        if case .valid(let username) = result {
            XCTAssertEqual(username, "alice")
        } else {
            XCTFail("Expected .valid, got \(result)")
        }
    }

    func testValidateTokenUsesTheLookupTimeout() async {
        let service = makeService()

        var capturedTimeout: TimeInterval?
        MockURLProtocol.requestHandler = { request in
            capturedTimeout = request.timeoutInterval
            let resp = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("alice".utf8))
        }

        _ = await service.validateToken("good-token")
        XCTAssertEqual(capturedTimeout, RequestTimeout.lookup)
    }

    /// Signing in waits the standard timeout, the one every CADC call has.
    func testLoginUsesTheStandardTimeout() async {
        let service = makeService()

        var capturedTimeout: TimeInterval?
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/login") == true { capturedTimeout = request.timeoutInterval }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        _ = await service.login(username: "alice", password: "wrong", rememberMe: false)
        XCTAssertEqual(capturedTimeout, RequestTimeout.standard)
    }

    func testValidateTokenReturnsExpiredOn401() async {
        let service = makeService()

        MockURLProtocol.requestHandler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let result = await service.validateToken("bad-token")
        if case .expired = result {
            // Expected
        } else {
            XCTFail("Expected .expired, got \(result)")
        }
    }

    func testValidateTokenReturnsNetworkErrorOnServerError() async {
        let service = makeService()

        MockURLProtocol.requestHandler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data("Internal Server Error".utf8))
        }

        let result = await service.validateToken("some-token")
        if case .networkError = result {
            // Expected — token should be preserved, not cleared
        } else {
            XCTFail("Expected .networkError, got \(result)")
        }
    }

    // MARK: - 401-interceptor bypass
    //
    // AppState wires NetworkClient's `onUnauthorized` interceptor to a
    // recovery path that calls `validateToken` (and, via silent reauth,
    // `login`). If those auth-flow requests themselves routed through the
    // interceptor, an expired token would recurse 401 → validate → 401 → …
    // forever — the app hangs on "Checking authentication…" at launch.
    // These tests pin the bypass: the interceptor must never fire for the
    // auth flow's own requests.

    private actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    func testValidateTokenDoesNotInvokeUnauthorizedInterceptorOn401() async {
        let network = NetworkClient(session: MockURLProtocol.mockSession())
        let service = AuthService(network: network)

        let interceptorCalls = CallCounter()
        await network.setUnauthorizedHandler {
            await interceptorCalls.increment()
            return true // would trigger a retry if the interceptor were consulted
        }

        MockURLProtocol.requestHandler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let result = await service.validateToken("expired-token")
        if case .expired = result {
            // Expected — the 401 surfaced directly instead of re-entering
            // the interceptor's validate-token recovery path.
        } else {
            XCTFail("Expected .expired, got \(result)")
        }
        let calls = await interceptorCalls.count
        XCTAssertEqual(calls, 0, "The /whoami validation probe must bypass the 401 interceptor")
    }

    func testLoginDoesNotInvokeUnauthorizedInterceptorOn401() async {
        let network = NetworkClient(session: MockURLProtocol.mockSession())
        let service = AuthService(network: network)

        let interceptorCalls = CallCounter()
        await network.setUnauthorizedHandler {
            await interceptorCalls.increment()
            return true
        }

        MockURLProtocol.requestHandler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let result = await service.login(username: "alice", password: "wrong")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorMessage, "Invalid username or password.")
        let calls = await interceptorCalls.count
        XCTAssertEqual(calls, 0, "The /login request must bypass the 401 interceptor")
    }

    func testValidateTokenReturnsExpiredOnEmptyUsername() async {
        let service = makeService()

        MockURLProtocol.requestHandler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("  \n".utf8))
        }

        let result = await service.validateToken("some-token")
        if case .expired = result {
            // Expected — empty username means invalid token
        } else {
            XCTFail("Expected .expired, got \(result)")
        }
    }
}
