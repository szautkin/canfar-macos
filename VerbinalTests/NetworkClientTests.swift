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

final class NetworkClientTests: XCTestCase {

    private func makeClient() -> NetworkClient {
        NetworkClient(session: MockURLProtocol.mockSession())
    }

    private func okResponse(
        url: String = "https://example.com",
        data: Data = Data()
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, data)
    }

    private func errorResponse(
        statusCode: Int,
        body: String = ""
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(body.utf8))
    }

    // MARK: - Auth Header

    func testGetRequestIncludesBearerToken() async throws {
        let client = makeClient()
        await client.setToken("test-token-123")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-token-123"
            )
            return self.okResponse(data: Data("ok".utf8))
        }

        _ = try await client.get("https://example.com/test")
    }

    func testGetRequestWithoutTokenHasNoAuthHeader() async throws {
        let client = makeClient()

        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return self.okResponse(data: Data("ok".utf8))
        }

        _ = try await client.get("https://example.com/test")
    }

    // MARK: - Error Handling

    func testUnauthorizedThrowsNetworkError() async {
        let client = makeClient()

        MockURLProtocol.requestHandler = { _ in
            self.errorResponse(statusCode: 401)
        }

        do {
            _ = try await client.get("https://example.com/test")
            XCTFail("Expected NetworkError.unauthorized")
        } catch let error as NetworkError {
            if case .unauthorized = error {
                // Expected
            } else {
                XCTFail("Expected unauthorized, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testHTTPErrorIncludesStatusCodeAndBody() async {
        let client = makeClient()

        MockURLProtocol.requestHandler = { _ in
            self.errorResponse(statusCode: 500, body: "Internal Server Error")
        }

        do {
            _ = try await client.get("https://example.com/test")
            XCTFail("Expected NetworkError.httpError")
        } catch let error as NetworkError {
            if case .httpError(let code, let body) = error {
                XCTAssertEqual(code, 500)
                XCTAssertEqual(body, "Internal Server Error")
            } else {
                XCTFail("Expected httpError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testInvalidURLThrowsNetworkError() async {
        let client = makeClient()

        do {
            _ = try await client.get("")
            XCTFail("Expected NetworkError.invalidURL")
        } catch let error as NetworkError {
            if case .invalidURL = error {
                // Expected
            } else {
                XCTFail("Expected invalidURL, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - GET

    func testGetJSONDecodesResponse() async throws {
        let client = makeClient()
        let json = #"{"username":"alice","email":"alice@example.com"}"#

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return self.okResponse(data: Data(json.utf8))
        }

        let user: UserInfo = try await client.getJSON(
            "https://example.com/user",
            type: UserInfo.self
        )
        XCTAssertEqual(user.username, "alice")
        XCTAssertEqual(user.email, "alice@example.com")
    }

    func testGetTextReturnsTrimmedString() async throws {
        let client = makeClient()

        MockURLProtocol.requestHandler = { _ in
            self.okResponse(data: Data("  hello world \n".utf8))
        }

        let text = try await client.getText("https://example.com/text")
        XCTAssertEqual(text, "hello world")
    }

    // MARK: - POST

    func testPostSendsFormEncodedBody() async throws {
        let client = makeClient()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded"
            )
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("username=alice"))
            XCTAssertTrue(body.contains("password=secret"))
            return self.okResponse(data: Data("token-abc".utf8))
        }

        _ = try await client.post(
            "https://example.com/login",
            formData: ["username": "alice", "password": "secret"]
        )
    }

    func testPostIncludesCustomHeaders() async throws {
        let client = makeClient()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Custom"), "value")
            return self.okResponse()
        }

        _ = try await client.post(
            "https://example.com/test",
            formData: [:],
            headers: ["X-Custom": "value"]
        )
    }

    // MARK: - DELETE

    func testDeleteUsesCorrectHTTPMethod() async throws {
        let client = makeClient()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            return self.okResponse()
        }

        _ = try await client.delete("https://example.com/resource/1")
    }

    // MARK: - NetworkError descriptions

    func testNetworkErrorDescriptions() {
        XCTAssertEqual(
            NetworkError.invalidURL("bad").errorDescription,
            "Invalid URL: bad"
        )
        XCTAssertEqual(
            NetworkError.invalidResponse.errorDescription,
            "Invalid server response"
        )
        XCTAssertEqual(
            NetworkError.unauthorized.errorDescription,
            "Authentication required"
        )
        XCTAssertEqual(
            NetworkError.httpError(404, "Not Found").errorDescription,
            "HTTP 404: Not Found"
        )
    }
}
