// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

public actor NetworkClient {
    private let session: URLSession
    public private(set) var token: String?
    /// Hosts the bearer token may be attached to. Token is *not* sent to any
    /// other host — important defense against forwarding the user's CADC
    /// credential to a third-party `accessURL` returned by DataLink or VOSpace.
    /// Hostnames are matched suffix-style (so `ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca`
    /// matches the catch-all `cadc-ccda.hia-iha.nrc-cnrc.gc.ca`); empty list
    /// means "send to nothing", which is the safe default for clients that
    /// haven't configured an allow-list.
    public private(set) var trustedAuthHostSuffixes: [String]

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    /// Optional callback invoked when a request returns 401 — the host
    /// surface (`AppState`) plugs in a token refresh / re-prompt here.
    /// Returns `true` if the client should retry the original request once;
    /// `false` if the 401 should propagate as `NetworkError.unauthorized`.
    public typealias UnauthorizedHandler = @Sendable () async -> Bool
    private var onUnauthorized: UnauthorizedHandler?

    public init(
        session: URLSession = .shared,
        trustedAuthHostSuffixes: [String] = NetworkClient.defaultCADCHosts
    ) {
        self.session = session
        self.trustedAuthHostSuffixes = trustedAuthHostSuffixes
    }

    public func setUnauthorizedHandler(_ handler: UnauthorizedHandler?) {
        self.onUnauthorized = handler
    }

    /// Default allow-list — the CADC + CANFAR domain families. Anything else
    /// (including DataLink redirects to partner archives) is treated as
    /// untrusted: requests still execute, but without our token.
    public static let defaultCADCHosts: [String] = [
        "cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
        "canfar.net",
    ]

    public func setToken(_ token: String?) {
        self.token = token
    }

    public func setTrustedAuthHostSuffixes(_ hosts: [String]) {
        self.trustedAuthHostSuffixes = hosts
    }

    /// Whether the bearer token would be attached to a request to `host`.
    /// Exposed for callers that need to decide whether to even make a call
    /// (e.g., authenticated endpoints).
    public func isTrustedAuthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return trustedAuthHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    // MARK: - HTTP Methods

    public func get(_ urlString: String, accept: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "GET")
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        return try await execute(request)
    }

    public func getText(_ urlString: String) async throws -> String {
        let (data, _) = try await get(urlString)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func getJSON<T: Decodable>(_ urlString: String, type: T.Type) async throws -> T {
        let (data, _) = try await get(urlString, accept: "application/json")
        return try Self.jsonDecoder.decode(T.self, from: data)
    }

    public func post(
        _ urlString: String,
        formData: [String: String],
        headers: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> (Data, HTTPURLResponse) {
        try await post(
            urlString,
            formPairs: formData.map { ($0.key, $0.value) },
            headers: headers,
            timeout: timeout
        )
    }

    /// POST with ordered `(key, value)` pairs — duplicate keys allowed.
    /// Skaha headless launches require multi-value form fields (e.g.
    /// `env=KEY1=VAL1` repeated per environment variable, matching the
    /// canonical Python `canfar` client). The dictionary variant above
    /// can't express that; this one is the single source of truth and
    /// the dictionary form delegates to it.
    public func post(
        _ urlString: String,
        formPairs: [(String, String)],
        headers: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "POST", timeout: timeout)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = formPairs
            .map { key, value in
                "\(Self.formEncode(key))=\(Self.formEncode(value))"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        if let headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        return try await execute(request)
    }

    /// Stricter than `.urlQueryAllowed`: also encodes `&`, `=`, `+`, `?`
    /// so they survive transit through a form-encoded body. Without this
    /// an env value like `FOO=bar&baz` would get parsed by the server as
    /// two separate fields.
    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.subtract(CharacterSet(charactersIn: "&=+?"))
        return set
    }()

    private static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }

    public func delete(_ urlString: String) async throws -> HTTPURLResponse {
        let request = try makeRequest(urlString, method: "DELETE")
        let (_, response) = try await execute(request)
        return response
    }

    public func put(
        _ urlString: String,
        body: Data,
        contentType: String,
        timeout: TimeInterval = 300
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "PUT", timeout: timeout)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await execute(request)
    }

    /// Stream a file from disk via `PUT`. Uses `URLSession.upload(for:fromFile:)`
    /// so the body is read incrementally instead of being materialised into
    /// memory — the right path for FITS-sized uploads where the in-memory
    /// `put(_:body:)` would peak at the file size.
    public func putFile(
        _ urlString: String,
        fileURL: URL,
        contentType: String,
        timeout: TimeInterval = 300
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "PUT", timeout: timeout)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw NetworkError.unauthorized
        }
        if httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.httpError(httpResponse.statusCode, body)
        }
        return (data, httpResponse)
    }

    // MARK: - Private

    private func makeRequest(_ urlString: String, method: String, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        // Attach the bearer token *only* to hosts in the trusted allow-list.
        // DataLink/VOSpace responses can redirect to partner archives whose
        // hostnames we didn't pre-approve; sending CADC credentials there
        // would leak the user's token cross-origin.
        if let token, !token.isEmpty, isTrustedAuthHost(url.host) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func execute(_ request: URLRequest, allowAuthRetry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            // Give the auth-lifecycle host one chance to refresh the token
            // (or surface a re-login UI) before we propagate the failure.
            // The handler returns true if a retry is worth attempting.
            if allowAuthRetry, let handler = onUnauthorized, await handler() {
                // Re-stamp the Authorization header off the freshly-set token
                // and retry once. `allowAuthRetry: false` prevents an
                // infinite loop if the refresh itself somehow yields 401.
                var retried = request
                if let url = retried.url, isTrustedAuthHost(url.host),
                   let token, !token.isEmpty {
                    retried.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                } else {
                    retried.setValue(nil, forHTTPHeaderField: "Authorization")
                }
                return try await execute(retried, allowAuthRetry: false)
            }
            throw NetworkError.unauthorized
        }
        if httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.httpError(httpResponse.statusCode, body)
        }
        return (data, httpResponse)
    }
}

public enum NetworkError: LocalizedError, Sendable {
    case invalidURL(String)
    case invalidResponse
    case unauthorized
    case httpError(Int, String)

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .invalidResponse: return "Invalid server response"
        case .unauthorized: return "Authentication required"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}
