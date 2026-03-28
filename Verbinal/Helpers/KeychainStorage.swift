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
import os.log

/// Stores auth credentials in Application Support with restrictive file permissions.
/// File-based storage avoids macOS Keychain prompts that occur on every rebuild
/// with ad-hoc signed apps.
enum KeychainStorage {
    private static let logger = Logger(subsystem: "net.canfar.Verbinal", category: "Auth")
    private static let fileName = "auth.json"

    private struct StoredCredentials: Codable {
        var token: String
        var username: String
    }

    static func saveToken(_ token: String, username: String) {
        guard let url = fileURL else { return }
        do {
            let creds = StoredCredentials(token: token, username: username)
            let data = try JSONEncoder().encode(creds)
            try data.write(to: url, options: .atomic)
            // Restrict to owner read/write only
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            logger.error("Failed to save credentials: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func loadToken() -> (token: String?, username: String?) {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return (nil, nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let creds = try JSONDecoder().decode(StoredCredentials.self, from: data)
            return (creds.token, creds.username)
        } catch {
            logger.warning("Failed to load credentials: \(error.localizedDescription, privacy: .public)")
            return (nil, nil)
        }
    }

    static func clearToken() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private static var fileURL: URL? {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal", isDirectory: true) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }
}
