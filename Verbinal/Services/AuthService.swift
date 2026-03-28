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

final class AuthService: Sendable {
    private let network: NetworkClient
    private let endpoints: APIEndpoints
    private let logger = Logger(subsystem: "net.canfar.Verbinal", category: "Auth")

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.endpoints = endpoints
    }

    /// Logs in with username/password. Returns an AuthResult.
    func login(username: String, password: String, rememberMe: Bool = true) async -> AuthResult {
        do {
            // POST form-urlencoded to /ac/login — response is plain text token
            let (data, _) = try await network.post(
                endpoints.loginURL,
                formData: ["username": username, "password": password]
            )

            guard let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                return AuthResult(success: false, errorMessage: "Empty token received")
            }

            // Set token on network client for subsequent requests
            await network.setToken(token)

            // Persist to Keychain if requested
            if rememberMe {
                KeychainStorage.saveToken(token, username: username)
            }

            // Fetch user info
            let userInfo = await getUserInfo(username: username)

            return AuthResult(
                success: true,
                token: token,
                username: username,
                userInfo: userInfo
            )
        } catch let error as NetworkError {
            if case .unauthorized = error {
                return AuthResult(success: false, errorMessage: "Invalid username or password.")
            }
            return AuthResult(success: false, errorMessage: error.localizedDescription)
        } catch {
            return AuthResult(success: false, errorMessage: error.localizedDescription)
        }
    }

    /// Validates a stored token by calling /whoami.
    /// Returns `.valid(username)`, `.expired`, or `.networkError`.
    func validateToken(_ token: String) async -> TokenValidation {
        await network.setToken(token)
        do {
            let username = try await network.getText(endpoints.whoAmIURL)
            return username.isEmpty ? .expired : .valid(username)
        } catch let error as NetworkError {
            if case .unauthorized = error {
                await network.setToken(nil)
                return .expired
            }
            // Keep the token — this is a transient network failure, not an auth problem
            return .networkError(error.localizedDescription ?? "Network error")
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    /// Fetches user profile info.
    func getUserInfo(username: String) async -> UserInfo? {
        do {
            return try await network.getJSON(endpoints.userURL(username), type: UserInfo.self)
        } catch {
            logger.warning("Failed to fetch user info: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Clears auth state.
    func logout() async {
        await network.setToken(nil)
        KeychainStorage.clearToken()
    }
}

struct AuthResult {
    var success: Bool
    var token: String?
    var username: String?
    var userInfo: UserInfo?
    var errorMessage: String?
}

enum TokenValidation {
    case valid(String)
    case expired
    case networkError(String)
}
