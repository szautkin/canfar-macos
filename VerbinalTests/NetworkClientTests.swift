// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
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

    func testGetRequestIncludesBearerTokenForTrustedHost() async throws {
        // The default trusted host list includes CADC + CANFAR. Issue the
        // request to a CADC host so the token attaches.
        let client = makeClient()
        await client.setToken("test-token-123")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-token-123"
            )
            return self.okResponse(data: Data("ok".utf8))
        }

        _ = try await client.get("https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync")
    }

    func testGetRequestWithoutTokenHasNoAuthHeader() async throws {
        let client = makeClient()

        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return self.okResponse(data: Data("ok".utf8))
        }

        _ = try await client.get("https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync")
    }

    func testGetRequestWithdrawsTokenFromUntrustedHost() async throws {
        // Critical security behaviour: a CADC token MUST NOT travel to a
        // third-party host (e.g., a DataLink response that points to a
        // partner archive).
        let client = makeClient()
        await client.setToken("test-token-123")

        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer token leaked to non-CADC host"
            )
            return self.okResponse(data: Data("ok".utf8))
        }

        _ = try await client.get("https://example.com/somewhere")
    }

    func testIsTrustedAuthHostMatchesSubdomains() async {
        let client = makeClient()
        let trusted1 = await client.isTrustedAuthHost("ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca")
        let trusted2 = await client.isTrustedAuthHost("ws-uv.canfar.net")
        let untrusted = await client.isTrustedAuthHost("example.com")
        let untrusted2 = await client.isTrustedAuthHost("evil-cadc-ccda.hia-iha.nrc-cnrc.gc.ca")
        let nilHost = await client.isTrustedAuthHost(nil)
        XCTAssertTrue(trusted1)
        XCTAssertTrue(trusted2)
        XCTAssertFalse(untrusted)
        XCTAssertFalse(untrusted2, "Suffix matching must require dot boundary")
        XCTAssertFalse(nilHost)
    }

    func testIsTrustedAuthHostMatchesExactAndDottedSuffix() async {
        let client = NetworkClient(
            session: MockURLProtocol.mockSession(),
            trustedAuthHostSuffixes: ["canfar.net"]
        )
        let exact = await client.isTrustedAuthHost("canfar.net")
        let dotted = await client.isTrustedAuthHost("ws-uv.canfar.net")
        let nonBoundary = await client.isTrustedAuthHost("evilcanfar.net")
        XCTAssertTrue(exact, "Exact host must match its own suffix entry")
        XCTAssertTrue(dotted, "Dotted-subdomain host must match")
        XCTAssertFalse(nonBoundary, "Match must require a dot boundary, not a bare string suffix")
    }

    func testIsTrustedAuthHostFalseForEmptyAllowList() async {
        let client = NetworkClient(
            session: MockURLProtocol.mockSession(),
            trustedAuthHostSuffixes: []
        )
        // Empty allow-list means "trust nothing" — the safe default.
        let trusted = await client.isTrustedAuthHost("ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca")
        let nilHost = await client.isTrustedAuthHost(nil)
        XCTAssertFalse(trusted, "Empty allow-list must not trust any host")
        XCTAssertFalse(nilHost, "nil host is never trusted")
    }

    func testTokenAttachmentTracksTrustedHostListUpdates() async throws {
        // Same host, two allow-list states: the token must attach only while
        // the host is on the list, demonstrating that setTrustedAuthHostSuffixes
        // is reflected by subsequent requests.
        let client = NetworkClient(
            session: MockURLProtocol.mockSession(),
            trustedAuthHostSuffixes: []
        )
        await client.setToken("tok-list-update")
        let host = "https://service.example.com/api"

        // Before: host not on the (empty) allow-list → no Authorization.
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(
                request.value(forHTTPHeaderField: "Authorization"),
                "Token must be withheld while host is untrusted"
            )
            return self.okResponse(url: host)
        }
        _ = try await client.get(host)

        // After: add the host's suffix → token now attaches.
        await client.setTrustedAuthHostSuffixes(["example.com"])
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer tok-list-update",
                "Token must attach once host becomes trusted"
            )
            return self.okResponse(url: host)
        }
        _ = try await client.get(host)
    }

    func testConfigureSetsTokenAndHostsAtomically() async throws {
        let client = NetworkClient(
            session: MockURLProtocol.mockSession(),
            trustedAuthHostSuffixes: []
        )
        await client.configure(
            token: "tok-configured",
            trustedAuthHostSuffixes: ["example.com"]
        )

        let token = await client.token
        let hosts = await client.trustedAuthHostSuffixes
        XCTAssertEqual(token, "tok-configured")
        XCTAssertEqual(hosts, ["example.com"])

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer tok-configured"
            )
            return self.okResponse(url: "https://api.example.com/x")
        }
        _ = try await client.get("https://api.example.com/x")
    }

    func testConcurrentSetTokenAndRequestLeaveConsistentState() async throws {
        // Hammer the actor with interleaved setToken writes and requests.
        // The actor serializes every call, so the token a request stamps is
        // always one of the values written (never a torn/partial value), and
        // the client's final token reflects the last serialized write.
        let client = NetworkClient(
            session: MockURLProtocol.mockSession(),
            trustedAuthHostSuffixes: ["example.com"]
        )
        let host = "https://api.example.com/ping"
        let allowed: Set<String?> = [
            nil,
            "Bearer tok-A",
            "Bearer tok-B",
            "Bearer tok-C",
        ]

        MockURLProtocol.requestHandler = { request in
            let header = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertTrue(
                allowed.contains(header),
                "Request stamped an unexpected (torn) Authorization value: \(header ?? "nil")"
            )
            return self.okResponse(url: host)
        }

        await withThrowingTaskGroup(of: Void.self) { group in
            for token in ["tok-A", "tok-B", "tok-C"] {
                group.addTask { await client.setToken(token) }
                group.addTask { _ = try await client.get(host) }
            }
            // Drain — ignore per-task throws; we only assert consistency.
            while let _ = try? await group.next() {}
        }

        // A final serialized write must be the value observed afterward.
        await client.setToken("tok-final")
        let finalToken = await client.token
        XCTAssertEqual(finalToken, "tok-final")
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

    func testPostFormPairsPreservesDuplicateKeysAndOrder() async throws {
        // Skaha headless launch needs `env=KEY=VAL` repeated per environment
        // variable. The dict-keyed `formData:` API can't express duplicates;
        // this test pins the ordered-pair API the headless service uses.
        let client = makeClient()

        MockURLProtocol.requestHandler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            // Order must be preserved exactly as supplied — header-line tools,
            // matchers, and even some servers depend on stable form ordering.
            XCTAssertEqual(
                body,
                "type=headless&env=FOO%3Dbar&env=BAZ%3Dqux&name=job-1"
            )
            return self.okResponse(data: Data("session-id\n".utf8))
        }

        _ = try await client.post(
            "https://example.com/skaha/v1/session",
            formPairs: [
                ("type", "headless"),
                ("env", "FOO=bar"),
                ("env", "BAZ=qux"),
                ("name", "job-1")
            ]
        )
    }

    func testPostFormPairsEncodesSpecialCharsInValues() async throws {
        let client = makeClient()

        MockURLProtocol.requestHandler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            // `=`, `&`, `+`, `?` in values must not corrupt the wire form
            // (they're the only chars beyond `.urlQueryAllowed` that we
            // strip — single-quote and parens stay literal because no
            // form parser splits on them). Space → %20.
            XCTAssertTrue(body.contains("cmd=python%20-c%20'print(1%2B2)'"),
                         "got body: \(body)")
            XCTAssertTrue(body.contains("env=A%3Db%26c"),
                         "got body: \(body)")
            return self.okResponse()
        }

        _ = try await client.post(
            "https://example.com/skaha/v1/session",
            formPairs: [
                ("cmd", "python -c 'print(1+2)'"),
                ("env", "A=b&c")
            ]
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
