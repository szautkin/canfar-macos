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

    /// Save a token + canonical username to the Keychain.
    ///
    /// Defensive: also wipes any pre-existing password account so an upgrade
    /// from a build that used to store passwords doesn't leave stale
    /// cleartext credentials on disk.
    public static func saveCredentials(token: String, username: String) {
        save(account: tokenAccount, data: token)
        save(account: usernameAccount, data: username)
        delete(account: passwordAccount)
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

    // MARK: - Generic key/value access

    /// Errors thrown by the generic `writeGeneric` / `readGeneric` /
    /// `deleteGeneric` surface. OSStatus codes that are treated as non-errors
    /// at the API boundary (`errSecItemNotFound` during a read or delete)
    /// never materialize here.
    public enum Error: Swift.Error, Equatable, LocalizedError {
        /// A `SecItem…` call returned a non-success, non-ignored OSStatus.
        case osStatus(OSStatus)
        /// Value string could not be UTF-8-encoded for storage.
        case invalidEncoding

        public var errorDescription: String? {
            switch self {
            case .osStatus(let code):
                return "Keychain operation failed (OSStatus \(code))."
            case .invalidEncoding:
                return "Keychain value could not be UTF-8 encoded."
            }
        }
    }

    /// Base query for generic read/write/delete — parameterized by `service`
    /// and `account` instead of the hard-coded CADC slot names. Honors the
    /// shared `accessGroup` set via `configure(accessGroup:)`.
    private static func genericBaseQuery(service: String, account: String) -> [String: Any] {
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

    /// Write an arbitrary UTF-8 string under `(service, account)`. Overwrites
    /// an existing item at the same key (delete-then-add, mirroring the CADC
    /// `save` helper). Designed for addons storing their own credentials
    /// outside the CADC token/username/password trio — e.g. the Thought
    /// addon's OpenAI API key, or a future Anthropic/Ollama token.
    ///
    /// - Throws: `KeychainStorage.Error` on OSStatus failure or encoding issue.
    public static func writeGeneric(
        _ value: String,
        service: String,
        account: String
    ) throws {
        guard let dataBytes = value.data(using: .utf8) else {
            throw Error.invalidEncoding
        }

        // Clear any existing item first so the add succeeds deterministically
        // without needing to branch on errSecDuplicateItem.
        let deleteQuery = genericBaseQuery(service: service, account: account)
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw Error.osStatus(deleteStatus)
        }

        var addQuery = genericBaseQuery(service: service, account: account)
        addQuery[kSecValueData as String] = dataBytes
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Error.osStatus(addStatus)
        }
    }

    /// Read a UTF-8 string at `(service, account)`. Returns `nil` when no item
    /// exists; throws for any other OSStatus failure.
    ///
    /// - Throws: `KeychainStorage.Error.osStatus` for any failure other than
    ///   `errSecItemNotFound`.
    public static func readGeneric(
        service: String,
        account: String
    ) throws -> String? {
        var query = genericBaseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Error.osStatus(status)
        }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            // Item exists but the stored bytes aren't valid UTF-8 — treat as
            // an encoding error so the caller can distinguish from "missing".
            throw Error.invalidEncoding
        }
        return string
    }

    /// Delete the item at `(service, account)`. Idempotent: a missing item is
    /// a silent no-op rather than a thrown error.
    ///
    /// - Throws: `KeychainStorage.Error.osStatus` for any failure other than
    ///   `errSecItemNotFound`.
    public static func deleteGeneric(
        service: String,
        account: String
    ) throws {
        let query = genericBaseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.osStatus(status)
        }
    }
}
