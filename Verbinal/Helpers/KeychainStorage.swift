// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Security
import os.log

enum KeychainStorage {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Keychain")
    private static let service = "com.codebg.Verbinal"
    private static let tokenAccount = "AuthToken"
    private static let usernameAccount = "Username"
    private static let passwordAccount = "Password"

    static func saveCredentials(token: String, username: String, password: String) {
        save(account: tokenAccount, data: token)
        save(account: usernameAccount, data: username)
        save(account: passwordAccount, data: password)
    }

    static func saveToken(_ token: String, username: String) {
        save(account: tokenAccount, data: token)
        save(account: usernameAccount, data: username)
    }

    static func loadToken() -> (token: String?, username: String?) {
        let token = load(account: tokenAccount)
        let username = load(account: usernameAccount)
        return (token, username)
    }

    static func loadCredentials() -> (username: String?, password: String?) {
        let username = load(account: usernameAccount)
        let password = load(account: passwordAccount)
        return (username, password)
    }

    /// Returns true if stored credentials include a password (user chose "Remember me").
    static var hasStoredPassword: Bool {
        load(account: passwordAccount) != nil
    }

    static func clearToken() {
        delete(account: tokenAccount)
        delete(account: usernameAccount)
        delete(account: passwordAccount)
    }

    // MARK: - Private

    private static func save(account: String, data: String) {
        guard let dataBytes = data.data(using: .utf8) else { return }

        // Delete existing item first
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: dataBytes,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Save failed for \(account, privacy: .public): OSStatus \(status)")
        }
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}
