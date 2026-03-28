// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
            switch error {
            case .unauthorized:
                await network.setToken(nil)
                return .expired
            case .httpError(let code, _) where code == 403:
                // 403 from /whoami = token is invalid
                await network.setToken(nil)
                return .expired
            default:
                // Actual network failure — keep the token
                return .networkError(error.localizedDescription)
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    /// Fetches user profile info from the CADC user service (XML response).
    func getUserInfo(username: String) async -> UserInfo? {
        do {
            let (data, _) = try await network.get(endpoints.userURL(username), accept: "text/xml")
            guard let xmlString = String(data: data, encoding: .utf8) else { return nil }
            logger.info("User XML response: \(xmlString, privacy: .public)")
            return parseUserXML(xmlString, username: username)
        } catch {
            logger.warning("Failed to fetch user info: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Parses CADC user XML to extract profile details.
    private func parseUserXML(_ xml: String, username: String) -> UserInfo? {
        guard let data = xml.data(using: .utf8) else {
            logger.error("parseUserXML: failed to convert string to data")
            return nil
        }

        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data)
        } catch {
            logger.error("parseUserXML: XMLDocument init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        func text(_ xpath: String) -> String? {
            (try? doc.nodes(forXPath: xpath))?.first?.stringValue
        }

        let firstName = text("//*[local-name()='firstName']")
        let lastName = text("//*[local-name()='lastName']")
        let email = text("//*[local-name()='email']")
        let institute = text("//*[local-name()='institute']")

        logger.info("Parsed user: firstName=\(firstName ?? "nil", privacy: .public) lastName=\(lastName ?? "nil", privacy: .public)")

        return UserInfo(
            username: username,
            email: email,
            firstName: firstName,
            lastName: lastName,
            institute: institute,
            internalID: nil
        )
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
