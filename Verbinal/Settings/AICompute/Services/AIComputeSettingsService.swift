// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// MainActor-bound observable store for `AIComputeSettings` — the
/// registry + credentials + image for the agent `run_code` tool.
///
/// Sibling of `ImageDiscoverySettingsService`, in a **separate keyspace**
/// (`com.codebg.Verbinal.aiCompute.*`) and a **separate Keychain service
/// id**, so the compute image's registry credentials are independent of
/// the inspector probe's. The Docker Registry V2 token-auth test is the
/// genuinely shared part, so we reuse `ImageDiscoverySettingsService`'s
/// `nonisolated static performCredentialTest` + `RegistryTestResult`
/// rather than duplicate the protocol dance.
@MainActor
@Observable
final class AIComputeSettingsService {

    // MARK: - Persistence keys
    private static let keyRegistryHost = "com.codebg.Verbinal.aiCompute.registryHost"
    private static let keyUsername     = "com.codebg.Verbinal.aiCompute.username"
    private static let keyImage        = "com.codebg.Verbinal.aiCompute.image"
    private static let keyCores        = "com.codebg.Verbinal.aiCompute.cores"
    private static let keyRam          = "com.codebg.Verbinal.aiCompute.ram"
    private nonisolated static let keychainServiceID = "com.codebg.Verbinal.aiCompute"

    private let userDefaults: UserDefaults
    private(set) var settings: AIComputeSettings

    // MARK: - Lifecycle

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        var loaded = AIComputeSettings()
        if let host = userDefaults.string(forKey: Self.keyRegistryHost), !host.isEmpty {
            loaded.registryHost = host
        }
        if let user = userDefaults.string(forKey: Self.keyUsername), !user.isEmpty {
            loaded.username = user
        }
        if let img = userDefaults.string(forKey: Self.keyImage), !img.isEmpty {
            loaded.image = img
        }
        // `object(forKey:)` so an explicitly-saved 1 isn't confused with
        // "never set" (which `integer(forKey:)` also reports as 0).
        if let cores = userDefaults.object(forKey: Self.keyCores) as? Int, cores >= 1 {
            loaded.cores = cores
        }
        if let ram = userDefaults.object(forKey: Self.keyRam) as? Int, ram >= 1 {
            loaded.ram = ram
        }
        loaded.hasSecret = ((try? Self.readSecret(
            host: loaded.registryHost, username: loaded.username)) ?? nil) != nil
        self.settings = loaded
    }

    // MARK: - Write knobs

    func setRegistryHost(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "images.canfar.net" : trimmed
        guard final != settings.registryHost else { return }
        userDefaults.set(final, forKey: Self.keyRegistryHost)
        settings.registryHost = final
        settings.hasSecret = ((try? Self.readSecret(host: final, username: settings.username)) ?? nil) != nil
    }

    func setUsername(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != settings.username else { return }
        userDefaults.set(trimmed, forKey: Self.keyUsername)
        settings.username = trimmed
        settings.hasSecret = ((try? Self.readSecret(host: settings.registryHost, username: trimmed)) ?? nil) != nil
    }

    /// Set the compute image. Empty genuinely unsets it (disabling
    /// `run_code`) — there is no built-in fallback image.
    func setImage(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != settings.image else { return }
        if trimmed.isEmpty {
            userDefaults.removeObject(forKey: Self.keyImage)
        } else {
            userDefaults.set(trimmed, forKey: Self.keyImage)
        }
        settings.image = trimmed
    }

    /// Set the default core count for the compute instance. Clamped to
    /// >= 1 (a 0-core request is the shared/flexible pool, which the
    /// compute watcher isn't sized for). Persisted to the same key the
    /// non-isolated `AIComputeImage.resolvedResources()` reads.
    func setCores(_ value: Int) {
        let clamped = max(1, value)
        guard clamped != settings.cores else { return }
        userDefaults.set(clamped, forKey: Self.keyCores)
        settings.cores = clamped
    }

    /// Set the default RAM (GB) for the compute instance. Same >= 1
    /// clamp + shared-key contract as `setCores`.
    func setRam(_ value: Int) {
        let clamped = max(1, value)
        guard clamped != settings.ram else { return }
        userDefaults.set(clamped, forKey: Self.keyRam)
        settings.ram = clamped
    }

    func setSecret(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try clearSecret(); return }
        guard !settings.username.isEmpty else { throw SettingsError.usernameRequired }
        try KeychainStorage.writeGeneric(
            trimmed,
            service: Self.keychainServiceID,
            account: keychainAccount(host: settings.registryHost, username: settings.username))
        settings.hasSecret = true
    }

    func clearSecret() throws {
        try KeychainStorage.deleteGeneric(
            service: Self.keychainServiceID,
            account: keychainAccount(host: settings.registryHost, username: settings.username))
        settings.hasSecret = false
    }

    func resetToDefaults() throws {
        try? clearSecret()
        userDefaults.removeObject(forKey: Self.keyRegistryHost)
        userDefaults.removeObject(forKey: Self.keyUsername)
        userDefaults.removeObject(forKey: Self.keyImage)
        userDefaults.removeObject(forKey: Self.keyCores)
        userDefaults.removeObject(forKey: Self.keyRam)
        settings = AIComputeSettings()
    }

    // MARK: - Launch credentials

    /// Raw `(username, secret)` for the `run_code` cold-launch path,
    /// which passes them to `SessionLaunchParams` so Skaha can mint the
    /// `x-skaha-registry-auth` header and pull a private image. Returns
    /// nil when username or secret is missing (public image / unset).
    func registryCredentials() -> (username: String, secret: String)? {
        guard !settings.username.isEmpty else { return nil }
        guard let secret = try? Self.readSecret(host: settings.registryHost, username: settings.username),
              !secret.isEmpty else { return nil }
        return (settings.username, secret)
    }

    // MARK: - Credential test (delegates to the shared V2 token-auth dance)

    func testRegistryCredentials(
        session: URLSession = .shared
    ) async -> ImageDiscoverySettingsService.RegistryTestResult {
        let host = settings.registryHost
        let user = settings.username
        guard !host.isEmpty else { return .missingConfiguration(reason: "Registry host is empty.") }
        guard !user.isEmpty else { return .missingConfiguration(reason: "Username is empty.") }
        guard let secret = try? Self.readSecret(host: host, username: user), !secret.isEmpty else {
            return .missingConfiguration(reason: "No secret stored — paste your Harbor CLI secret and click Save Secret first.")
        }
        return await ImageDiscoverySettingsService.performCredentialTest(
            host: host, user: user, secret: secret, session: session)
    }

    // MARK: - Keychain plumbing

    private nonisolated static func readSecret(host: String, username: String) throws -> String? {
        guard !username.isEmpty else { return nil }
        return try KeychainStorage.readGeneric(service: keychainServiceID, account: "\(host):\(username)")
    }

    private nonisolated func keychainAccount(host: String, username: String) -> String {
        "\(host):\(username)"
    }

    // MARK: - Errors

    enum SettingsError: LocalizedError {
        case usernameRequired
        var errorDescription: String? {
            switch self {
            case .usernameRequired: return "Set a registry username before storing a secret."
            }
        }
    }
}
