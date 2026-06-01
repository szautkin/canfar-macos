// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// MainActor-bound observable store for `ImageDiscoverySettings`.
///
/// Persistence is split by sensitivity:
///   * Non-secret fields (`registryHost`, `username`, `inspectorImage`)
///     live in `UserDefaults` under the
///     `com.codebg.Verbinal.imageDiscovery.*` keyspace.
///   * The secret lives in the macOS Keychain under
///     `(service: "com.codebg.Verbinal.imageDiscovery", account: "<host>:<user>")`,
///     so multi-account users keep distinct credentials and switching
///     `(host, username)` doesn't accidentally surface the wrong
///     secret.
///
/// All write methods are synchronous from the caller's perspective —
/// Keychain operations happen on the main thread but are sub-millisecond
/// for the small values we store (typical Harbor CLI secret is a 32-char
/// hex string).
@MainActor
@Observable
final class ImageDiscoverySettingsService {

    // MARK: - Persistence keys

    private static let keyRegistryHost    = "com.codebg.Verbinal.imageDiscovery.registryHost"
    private static let keyUsername        = "com.codebg.Verbinal.imageDiscovery.username"
    private static let keyInspectorImage  = "com.codebg.Verbinal.imageDiscovery.inspectorImage"
    private nonisolated static let keychainServiceID  = "com.codebg.Verbinal.imageDiscovery"

    private let userDefaults: UserDefaults

    /// Observable settings view. Mutations land here AFTER the
    /// underlying UserDefaults / Keychain write succeeds, so the
    /// UI reflects persisted state, not optimistic state.
    private(set) var settings: ImageDiscoverySettings

    // MARK: - Lifecycle

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        var loaded = ImageDiscoverySettings()
        if let host = userDefaults.string(forKey: Self.keyRegistryHost), !host.isEmpty {
            loaded.registryHost = host
        }
        if let user = userDefaults.string(forKey: Self.keyUsername), !user.isEmpty {
            loaded.username = user
        }
        if let img = userDefaults.string(forKey: Self.keyInspectorImage), !img.isEmpty {
            loaded.inspectorImage = img
        }
        // Probe the Keychain for an existing secret under the
        // current (host, username) pair. Catch all errors — a
        // Keychain failure here must not block app startup.
        loaded.hasSecret = ((try? Self.readSecret(
            host: loaded.registryHost,
            username: loaded.username
        )) ?? nil) != nil
        self.settings = loaded
    }

    // MARK: - Write knobs

    func setRegistryHost(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "images.canfar.net" : trimmed
        guard final != settings.registryHost else { return }
        userDefaults.set(final, forKey: Self.keyRegistryHost)
        settings.registryHost = final
        // The Keychain account is (host:username); when host
        // changes, refresh the hasSecret flag to reflect the new
        // pair's presence.
        settings.hasSecret = ((try? Self.readSecret(host: final, username: settings.username)) ?? nil) != nil
    }

    func setUsername(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != settings.username else { return }
        userDefaults.set(trimmed, forKey: Self.keyUsername)
        settings.username = trimmed
        settings.hasSecret = ((try? Self.readSecret(host: settings.registryHost, username: trimmed)) ?? nil) != nil
    }

    func setInspectorImage(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? ImageDiscoverySettings.defaultInspectorImage : trimmed
        guard final != settings.inspectorImage else { return }
        userDefaults.set(final, forKey: Self.keyInspectorImage)
        settings.inspectorImage = final
    }

    /// Persist a secret for the current `(registryHost, username)`
    /// pair. Empty `value` is treated as a clear (same as
    /// `clearSecret`) so a single SecureField + Save flow
    /// double-duties.
    func setSecret(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try clearSecret()
            return
        }
        guard !settings.username.isEmpty else {
            // Without a username the Keychain account would be
            // `host:` — meaningless. Surface a clear error.
            throw SettingsError.usernameRequired
        }
        try KeychainStorage.writeGeneric(
            trimmed,
            service: Self.keychainServiceID,
            account: keychainAccount(host: settings.registryHost, username: settings.username)
        )
        settings.hasSecret = true
    }

    func clearSecret() throws {
        try KeychainStorage.deleteGeneric(
            service: Self.keychainServiceID,
            account: keychainAccount(host: settings.registryHost, username: settings.username)
        )
        settings.hasSecret = false
    }

    /// Erase every knob. Useful for "I'm done with this Mac"
    /// teardown; the Settings UI exposes this behind a destructive
    /// Reset button.
    func resetToDefaults() throws {
        try? clearSecret()
        userDefaults.removeObject(forKey: Self.keyRegistryHost)
        userDefaults.removeObject(forKey: Self.keyUsername)
        userDefaults.removeObject(forKey: Self.keyInspectorImage)
        settings = ImageDiscoverySettings()
    }

    // MARK: - Auth header for the probe path

    /// Build the `x-skaha-registry-auth` header value (or `nil`
    /// when credentials are absent). Reads the secret from the
    /// Keychain on demand — the secret is not cached in memory
    /// beyond the duration of this call.
    ///
    /// Returns `nil` when:
    ///   * username is empty, OR
    ///   * no Keychain entry exists for `(host, username)`, OR
    ///   * the Keychain read fails for any reason (the caller
    ///     proceeds without the header; Skaha will surface the
    ///     401/400 the user already saw).
    func currentAuthHeader() -> String? {
        guard !settings.username.isEmpty else { return nil }
        // `try?` flattens here — `readSecret` throws and returns
        // `String?`, so `try?` yields a single-optional `String?`.
        guard let secret = try? Self.readSecret(
            host: settings.registryHost,
            username: settings.username
        ) else { return nil }
        let raw = "\(settings.username):\(secret)"
        guard let data = raw.data(using: .utf8) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Keychain plumbing

    private nonisolated static func readSecret(host: String, username: String) throws -> String? {
        guard !username.isEmpty else { return nil }
        let account = "\(host):\(username)"
        return try KeychainStorage.readGeneric(
            service: keychainServiceID,
            account: account
        )
    }

    private nonisolated func keychainAccount(host: String, username: String) -> String {
        "\(host):\(username)"
    }

    // MARK: - Errors

    enum SettingsError: LocalizedError {
        case usernameRequired

        var errorDescription: String? {
            switch self {
            case .usernameRequired:
                return "Set a registry username before storing a secret."
            }
        }
    }

    // MARK: - Credential test

    /// Outcome of `testRegistryCredentials()`. Distinct cases let
    /// the UI render different icons / colours per state instead
    /// of one generic "failed" label.
    enum RegistryTestResult: Equatable, Sendable {
        /// Token endpoint returned 200 — Harbor confirms these
        /// credentials are valid. The associated message is a
        /// short human note ("Credentials valid.") for the UI to
        /// display.
        case success(message: String)
        /// Token endpoint returned 401 or 403 — credentials
        /// reached Harbor but Harbor rejected them. Most common
        /// cause: user entered their CADC password instead of
        /// the Harbor CLI secret, or the CLI secret has expired.
        case unauthorized
        /// One of `registryHost`, `username`, or the Keychain
        /// secret is missing. The reason is included so the UI
        /// can tell the user exactly which field to fix.
        case missingConfiguration(reason: String)
        /// Registry responded with `WWW-Authenticate` we couldn't
        /// parse, or didn't challenge at all. Surfaces in the
        /// UI as "registry behaving unexpectedly" — likely a
        /// non-Harbor host or a misconfigured one.
        case invalidChallenge(message: String)
        /// DNS, TLS, timeout, or an unexpected HTTP status that
        /// isn't 200/401/403. The wrapped message is the
        /// `URLError.localizedDescription` or a brief
        /// "HTTP NNN" string.
        case networkError(message: String)
    }

    /// Probe the configured registry to verify the stored
    /// credentials BEFORE the user submits a probe job that
    /// would otherwise fail with a K8s `ImagePullBackOff` five
    /// minutes later.
    ///
    /// Performs the Docker Registry V2 token-auth dance:
    ///   1. `GET https://<host>/v2/` with no auth →
    ///      Harbor responds 401 with
    ///      `WWW-Authenticate: Bearer realm="…", service="…"`.
    ///   2. Parse the realm + service from the challenge.
    ///   3. `GET <realm>?service=<service>` with
    ///      `Authorization: Basic base64(user:secret)` →
    ///      200 means the credentials are valid (Harbor would
    ///      issue a token); 401/403 means the credentials are
    ///      rejected.
    ///
    /// The implementation is intentionally non-Harbor-specific —
    /// any OCI-compliant registry following the V2 token
    /// protocol works here (Docker Hub, Quay, GHCR, etc.).
    ///
    /// `session` is injectable so tests can replace
    /// `URLSession.shared` with a `MockURLProtocol`-backed
    /// session and exercise every result path without real
    /// network. Per-request timeout: 10s — long enough to ride
    /// out a slow TLS handshake, short enough that the UI
    /// doesn't hang on a dead host.
    func testRegistryCredentials(
        session: URLSession = .shared
    ) async -> RegistryTestResult {
        let host = settings.registryHost
        let user = settings.username
        guard !host.isEmpty else {
            return .missingConfiguration(reason: "Registry host is empty.")
        }
        guard !user.isEmpty else {
            return .missingConfiguration(reason: "Username is empty.")
        }
        // `try?` flattens here — `readSecret` throws and returns
        // `String?`, so `try?` yields a single-optional `String?`.
        guard let secret = try? Self.readSecret(host: host, username: user),
              !secret.isEmpty else {
            return .missingConfiguration(reason: "No secret stored — paste your Harbor CLI secret and click Save Secret first.")
        }
        return await Self.performCredentialTest(
            host: host,
            user: user,
            secret: secret,
            session: session
        )
    }

    /// Pure network half of `testRegistryCredentials` — no
    /// Keychain access, no settings reads. Tests drive this
    /// directly via `MockURLProtocol` so they don't have to
    /// write real secrets to the Keychain (which would pollute
    /// the user's real keystore between runs).
    ///
    /// `host` is the bare hostname (no scheme). `user` and
    /// `secret` are sent as `Basic base64(user:secret)` on the
    /// token endpoint. `session` is injected so MockURLProtocol
    /// can intercept.
    nonisolated static func performCredentialTest(
        host: String,
        user: String,
        secret: String,
        session: URLSession
    ) async -> RegistryTestResult {
        guard !host.isEmpty else {
            return .missingConfiguration(reason: "Registry host is empty.")
        }
        guard !user.isEmpty else {
            return .missingConfiguration(reason: "Username is empty.")
        }
        guard !secret.isEmpty else {
            return .missingConfiguration(reason: "No secret stored — paste your Harbor CLI secret and click Save Secret first.")
        }

        // Step 1: ping /v2/ to discover the auth realm.
        guard let pingURL = URL(string: "https://\(host)/v2/") else {
            return .networkError(message: "Could not construct https://\(host)/v2/")
        }
        var pingRequest = URLRequest(url: pingURL)
        pingRequest.httpMethod = "GET"
        pingRequest.timeoutInterval = 10
        let pingResponse: HTTPURLResponse
        do {
            let (_, raw) = try await session.data(for: pingRequest)
            guard let http = raw as? HTTPURLResponse else {
                return .networkError(message: "Registry returned a non-HTTP response.")
            }
            pingResponse = http
        } catch {
            return .networkError(message: error.localizedDescription)
        }

        // Some registries return 200 here (no auth required) —
        // that's actually success: anyone can pull, no token
        // needed. Surface it as such so the user knows.
        if (200..<300).contains(pingResponse.statusCode) {
            return .success(message: "Registry is publicly accessible — no credentials needed for image pulls.")
        }

        // Anything other than 401 + WWW-Authenticate is unexpected.
        guard pingResponse.statusCode == 401,
              let challenge = pingResponse.value(forHTTPHeaderField: "WWW-Authenticate") else {
            return .networkError(message: "Unexpected HTTP \(pingResponse.statusCode) from \(host)/v2/")
        }

        // Step 2: parse the Bearer challenge.
        guard let parsed = parseBearerChallenge(challenge) else {
            return .invalidChallenge(message: "Could not parse WWW-Authenticate: \(challenge)")
        }
        guard let realm = parsed.realm, let realmURL = URL(string: realm) else {
            return .invalidChallenge(message: "Bearer challenge missing or malformed realm.")
        }

        // Step 3: GET <realm>?service=<service> with Basic auth.
        var components = URLComponents(url: realmURL, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = components?.queryItems ?? []
        if let service = parsed.service {
            queryItems.append(URLQueryItem(name: "service", value: service))
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let tokenURL = components?.url else {
            return .invalidChallenge(message: "Could not construct token URL from realm \(realm)")
        }

        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "GET"
        tokenRequest.timeoutInterval = 10
        let basicAuth = "\(user):\(secret)"
        guard let basicData = basicAuth.data(using: .utf8) else {
            return .networkError(message: "Could not UTF-8 encode credentials.")
        }
        tokenRequest.setValue(
            "Basic \(basicData.base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )

        do {
            let (_, raw) = try await session.data(for: tokenRequest)
            guard let http = raw as? HTTPURLResponse else {
                return .networkError(message: "Token endpoint returned a non-HTTP response.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .unauthorized
            }
            if (200..<300).contains(http.statusCode) {
                return .success(message: "Credentials valid. Harbor issued an auth token successfully.")
            }
            return .networkError(message: "Token endpoint returned HTTP \(http.statusCode).")
        } catch {
            return .networkError(message: error.localizedDescription)
        }
    }

    /// Parse a Docker Registry V2 `WWW-Authenticate: Bearer …`
    /// challenge into its `realm` + `service` parameters.
    ///
    /// Tolerates:
    ///   * `Bearer realm="x", service="y"` (standard form)
    ///   * additional parameters (`scope`, `error`, etc.) which
    ///     we ignore
    ///   * single OR double quotes around values
    ///   * stray whitespace
    ///
    /// Returns `nil` when the header doesn't lead with `Bearer`
    /// (challenge scheme is something else like `Basic`).
    nonisolated static func parseBearerChallenge(
        _ challenge: String
    ) -> (realm: String?, service: String?)? {
        let trimmed = challenge.trimmingCharacters(in: .whitespaces)
        let lowercased = trimmed.lowercased()
        guard lowercased.hasPrefix("bearer ") || lowercased == "bearer" else {
            return nil
        }
        let afterScheme = trimmed.dropFirst("Bearer".count)
            .trimmingCharacters(in: .whitespaces)

        var realm: String?
        var service: String?

        // Split on commas, but only at the top level (values
        // are quoted — no embedded commas within quotes in
        // the Bearer challenge format).
        let parts = afterScheme.split(separator: ",")
        for part in parts {
            let kv = part.trimmingCharacters(in: .whitespaces)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let key = kv[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = kv[kv.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes (either ' or ").
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "realm":   realm = value
            case "service": service = value
            default: break
            }
        }

        return (realm, service)
    }
}
