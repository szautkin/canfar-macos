// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Coverage for the "Test Connection" feature in
/// Settings → Discovery. Validates the Docker Registry V2
/// token-auth dance against canned `MockURLProtocol` responses
/// so we exercise every `RegistryTestResult` branch without
/// touching the real Keychain or hitting Harbor.
///
/// 2026-05-20 addition: closes the K8s `ImagePullBackOff`
/// debugging loop by surfacing bad credentials at entry time
/// instead of five minutes into a Pending probe.
final class RegistryCredentialTestTests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    // MARK: - parseBearerChallenge

    func testParseBearerChallengeStandardForm() {
        let parsed = ImageDiscoverySettingsService.parseBearerChallenge(
            #"Bearer realm="https://harbor.example/service/token",service="harbor-registry""#
        )
        XCTAssertEqual(parsed?.realm, "https://harbor.example/service/token")
        XCTAssertEqual(parsed?.service, "harbor-registry")
    }

    func testParseBearerChallengeIgnoresUnknownKeys() {
        let parsed = ImageDiscoverySettingsService.parseBearerChallenge(
            #"Bearer realm="https://x/y",service="s",scope="repository:foo:pull",error="invalid_token""#
        )
        XCTAssertEqual(parsed?.realm, "https://x/y")
        XCTAssertEqual(parsed?.service, "s")
    }

    func testParseBearerChallengeAcceptsLowercaseScheme() {
        // RFC 7235 says the scheme name is case-insensitive.
        let parsed = ImageDiscoverySettingsService.parseBearerChallenge(
            #"bearer realm="https://x/y", service="s""#
        )
        XCTAssertEqual(parsed?.realm, "https://x/y")
        XCTAssertEqual(parsed?.service, "s")
    }

    func testParseBearerChallengeStripsQuotes() {
        // Single quotes shouldn't be standard but accept them
        // defensively — some registries emit non-conformant
        // challenges.
        let parsed = ImageDiscoverySettingsService.parseBearerChallenge(
            #"Bearer realm='https://x/y', service='s'"#
        )
        XCTAssertEqual(parsed?.realm, "https://x/y")
        XCTAssertEqual(parsed?.service, "s")
    }

    func testParseBearerChallengeRejectsNonBearerScheme() {
        XCTAssertNil(ImageDiscoverySettingsService.parseBearerChallenge(
            #"Basic realm="x""#
        ))
    }

    func testParseBearerChallengeEmptyReturnsNil() {
        XCTAssertNil(ImageDiscoverySettingsService.parseBearerChallenge(""))
    }

    // MARK: - performCredentialTest — missing configuration

    func testMissingHostReturnsMissingConfiguration() async {
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "", user: "alice", secret: "s",
            session: MockURLProtocol.mockSession()
        )
        XCTAssertEqual(result, .missingConfiguration(reason: "Registry host is empty."))
    }

    func testMissingUsernameReturnsMissingConfiguration() async {
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "images.canfar.net", user: "", secret: "s",
            session: MockURLProtocol.mockSession()
        )
        XCTAssertEqual(result, .missingConfiguration(reason: "Username is empty."))
    }

    func testMissingSecretReturnsMissingConfiguration() async {
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "images.canfar.net", user: "alice", secret: "",
            session: MockURLProtocol.mockSession()
        )
        guard case .missingConfiguration = result else {
            XCTFail("expected missingConfiguration, got \(result)")
            return
        }
    }

    // MARK: - performCredentialTest — V2 token dance

    /// Standard Harbor flow: /v2/ → 401 with challenge → token
    /// endpoint with Basic auth → 200 → `.success`.
    func testValidCredentialsReachTokenAndSucceed() async {
        MockURLProtocol.requestHandler = { req in
            let url = req.url!
            if url.path == "/v2/" || url.path == "/v2" {
                let resp = HTTPURLResponse(
                    url: url, statusCode: 401, httpVersion: nil,
                    headerFields: [
                        "WWW-Authenticate": #"Bearer realm="https://images.canfar.net/service/token",service="harbor-registry""#
                    ]
                )!
                return (resp, Data())
            }
            if url.path.contains("/service/token") {
                // The Basic auth header must be present.
                XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
                let resp = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (resp, #"{"token":"abc","expires_in":3600,"issued_at":"2026-05-20T00:00:00Z"}"#.data(using: .utf8)!)
            }
            return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "images.canfar.net", user: "alice", secret: "supersecret",
            session: MockURLProtocol.mockSession()
        )
        guard case .success = result else {
            XCTFail("expected success, got \(result)")
            return
        }
    }

    /// Token endpoint returns 401 — Harbor rejected the
    /// credentials. This is the QA-named failure mode (user
    /// entered CADC password instead of Harbor CLI secret).
    func testBadCredentialsAt401Token() async {
        MockURLProtocol.requestHandler = { req in
            let url = req.url!
            if url.path == "/v2/" || url.path == "/v2" {
                let resp = HTTPURLResponse(
                    url: url, statusCode: 401, httpVersion: nil,
                    headerFields: [
                        "WWW-Authenticate": #"Bearer realm="https://x/token",service="x""#
                    ]
                )!
                return (resp, Data())
            }
            // Token endpoint rejects.
            let resp = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "x.example", user: "alice", secret: "wrong",
            session: MockURLProtocol.mockSession()
        )
        XCTAssertEqual(result, .unauthorized)
    }

    /// 403 on the token endpoint is equivalent to 401 for
    /// credential-validation purposes — Harbor reached the user
    /// but said no.
    func testTokenEndpoint403IsAlsoUnauthorized() async {
        MockURLProtocol.requestHandler = { req in
            let url = req.url!
            if url.path == "/v2/" || url.path == "/v2" {
                let resp = HTTPURLResponse(
                    url: url, statusCode: 401, httpVersion: nil,
                    headerFields: [
                        "WWW-Authenticate": #"Bearer realm="https://x/token",service="x""#
                    ]
                )!
                return (resp, Data())
            }
            let resp = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "x.example", user: "alice", secret: "s",
            session: MockURLProtocol.mockSession()
        )
        XCTAssertEqual(result, .unauthorized)
    }

    /// Some registries (Docker Hub anonymous) return 200 on
    /// `/v2/` directly — no auth needed. Surface this as
    /// success with an explanatory message so the user knows
    /// their creds weren't actually consulted.
    func testPublicRegistryReturnsSuccess() async {
        MockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "public.example", user: "alice", secret: "s",
            session: MockURLProtocol.mockSession()
        )
        guard case .success(let message) = result else {
            XCTFail("expected success, got \(result)")
            return
        }
        XCTAssertTrue(message.contains("publicly accessible"),
                      "message should distinguish public-registry success; got '\(message)'")
    }

    /// `/v2/` returns 401 but with a non-Bearer (Basic) challenge.
    /// Surface as `.invalidChallenge` — the user's registry isn't
    /// behaving as a Docker V2-compatible host.
    func testNonBearerChallengeReturnsInvalidChallenge() async {
        MockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 401, httpVersion: nil,
                headerFields: ["WWW-Authenticate": #"Basic realm="legacy""#]
            )!
            return (resp, Data())
        }
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "weird.example", user: "alice", secret: "s",
            session: MockURLProtocol.mockSession()
        )
        guard case .invalidChallenge = result else {
            XCTFail("expected invalidChallenge, got \(result)")
            return
        }
    }

    /// `/v2/` returns 401 with NO WWW-Authenticate header. Surface
    /// as `.networkError` — protocol violation.
    func testMissingChallengeReturnsNetworkError() async {
        MockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "rude.example", user: "alice", secret: "s",
            session: MockURLProtocol.mockSession()
        )
        guard case .networkError = result else {
            XCTFail("expected networkError, got \(result)")
            return
        }
    }

    /// Unexpected status (e.g. 500) on the ping endpoint surfaces
    /// as `.networkError` with the code so the user can
    /// diagnose.
    func testUnexpectedStatusOnPingReturnsNetworkError() async {
        MockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "down.example", user: "alice", secret: "s",
            session: MockURLProtocol.mockSession()
        )
        guard case .networkError(let message) = result else {
            XCTFail("expected networkError, got \(result)")
            return
        }
        XCTAssertTrue(message.contains("502"),
                      "status code must appear in the error so the user knows what they saw; got '\(message)'")
    }

    /// URLSession throws (DNS failure, timeout) → `.networkError`
    /// with the underlying message.
    func testNetworkFailureReturnsNetworkError() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotFindHost)
        }
        let result = await ImageDiscoverySettingsService.performCredentialTest(
            host: "nope.example", user: "alice", secret: "s",
            session: MockURLProtocol.mockSession()
        )
        guard case .networkError = result else {
            XCTFail("expected networkError, got \(result)")
            return
        }
    }
}
