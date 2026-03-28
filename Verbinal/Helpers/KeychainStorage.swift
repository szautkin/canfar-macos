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

import Foundation
import Security
import os.log

enum KeychainStorage {
    private static let logger = Logger(subsystem: "net.canfar.Verbinal", category: "Keychain")
    private static let service = "net.canfar.Verbinal"
    private static let tokenAccount = "AuthToken"
    private static let usernameAccount = "Username"

    static func saveToken(_ token: String, username: String) {
        save(account: tokenAccount, data: token)
        save(account: usernameAccount, data: username)
    }

    static func loadToken() -> (token: String?, username: String?) {
        let token = load(account: tokenAccount)
        let username = load(account: usernameAccount)
        return (token, username)
    }

    static func clearToken() {
        delete(account: tokenAccount)
        delete(account: usernameAccount)
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
