// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Security
import os.log

/// Keychain-backed token + credential storage shared between the Verbinal host
/// app and every first-party addon.
///
/// Items are stored under `kSecAttrAccessible = WhenUnlockedThisDeviceOnly` so
/// they never sync to iCloud Keychain or migrate with Time Machine across devices.
///
/// ### Cross-SKU sharing
///
/// When the host and addons ship under the same Apple Team ID, they can share
/// the Keychain access group declared in each target's `keychain-access-groups`
/// entitlement. Call `KeychainStorage.configure(accessGroup:)` once at app launch
/// to route all reads/writes through that group:
///
/// ```swift
/// KeychainStorage.configure(accessGroup: "A4ABW5VD88.codebg.verbinal.family")
/// ```
///
/// If `configure` is never called (or called with nil), items are stored in the
/// app's default access group (keyed by bundle ID) and are not visible to other
/// apps. That is the correct behavior for the slim Verbinal build today.
public enum KeychainStorage {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Keychain")

    /// Service identifier used as `kSecAttrService` on every item written.
    /// Host and addons share this value so they index into the same items.
    /// Mutated only via `configure(service:accessGroup:)`.
    public private(set) static var service: String = "com.codebg.Verbinal"

    /// Shared Keychain access group. `nil` = app-default (bundle-scoped) access.
    /// When set, every query includes `kSecAttrAccessGroup` so items are visible
    /// to every target whose entitlements declare that group.
    /// Mutated only via `configure(service:accessGroup:)`.
    public private(set) static var accessGroup: String?

    private static let tokenAccount = "AuthToken"
    private static let usernameAccount = "Username"
    private static let passwordAccount = "Password"

    /// Call once at app launch to configure cross-SKU sharing. Both `service`
    /// and `accessGroup` are optional — unset parameters keep the previous
    /// (or default) value.
    public static func configure(service: String? = nil, accessGroup: String? = nil) {
        if let service { Self.service = service }
        if let accessGroup { Self.accessGroup = accessGroup }
    }

    public static func saveCredentials(token: String, username: String, password: String) {
        save(account: tokenAccount, data: token)
        save(account: usernameAccount, data: username)
        save(account: passwordAccount, data: password)
    }

    public static func saveToken(_ token: String, username: String) {
        save(account: tokenAccount, data: token)
        save(account: usernameAccount, data: username)
    }

    public static func loadToken() -> (token: String?, username: String?) {
        let token = load(account: tokenAccount)
        let username = load(account: usernameAccount)
        return (token, username)
    }

    public static func loadCredentials() -> (username: String?, password: String?) {
        let username = load(account: usernameAccount)
        let password = load(account: passwordAccount)
        return (username, password)
    }

    /// Returns true if stored credentials include a password (user chose "Remember me").
    public static var hasStoredPassword: Bool {
        load(account: passwordAccount) != nil
    }

    public static func clearToken() {
        delete(account: tokenAccount)
        delete(account: usernameAccount)
        delete(account: passwordAccount)
    }

    // MARK: - Private

    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func save(account: String, data: String) {
        guard let dataBytes = data.data(using: .utf8) else { return }

        // Delete existing item first
        delete(account: account)

        var query = baseQuery(account: account)
        query[kSecValueData as String] = dataBytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Save failed for \(account, privacy: .public): OSStatus \(status)")
        }
    }

    private static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }
}
