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
