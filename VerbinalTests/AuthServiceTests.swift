// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
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
