// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

public final class AuthService: Sendable {
    private let network: NetworkClient
    private let endpoints: APIEndpoints
    private let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Auth")

    public init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.endpoints = endpoints
    }

    /// Logs in with username/password. Returns an AuthResult.
    public func login(username: String, password: String, rememberMe: Bool = true) async -> AuthResult {
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

            // Get canonical username from /whoami (case-sensitive for storage paths).
            // Don't use validateToken() here — it clears the token on failure.
            let canonicalUsername: String
            if let apiUsername = try? await network.getText(endpoints.whoAmIURL),
               !apiUsername.isEmpty {
                canonicalUsername = apiUsername
            } else {
                canonicalUsername = username.lowercased()
            }

            // Persist token + username to Keychain if requested.
            //
            // The password is *not* persisted: once we have a token,
            // re-authentication uses the token (or re-prompts the user) —
            // there is no flow that needs the original password later.
            // Storing it would only enlarge the Keychain blast radius.
            if rememberMe {
                KeychainStorage.saveCredentials(token: token, username: canonicalUsername)
            }

            // Fetch user info
            let userInfo = await getUserInfo(username: canonicalUsername)

            return AuthResult(
                success: true,
                token: token,
                username: canonicalUsername,
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
    public func validateToken(_ token: String) async -> TokenValidation {
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
    public func getUserInfo(username: String) async -> UserInfo? {
        do {
            let (data, _) = try await network.get(endpoints.userURL(username), accept: "text/xml")
            guard let xmlString = String(data: data, encoding: .utf8) else { return nil }
            logger.debug("User XML response: \(xmlString, privacy: .private)")
            return parseUserXML(xmlString, username: username)
        } catch {
            logger.warning("Failed to fetch user info: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Parses CADC user XML to extract profile details.
    private func parseUserXML(_ xml: String, username: String) -> UserInfo? {
        let firstName = SimpleXML.textOfFirst(localName: "firstName", in: xml)
        let lastName = SimpleXML.textOfFirst(localName: "lastName", in: xml)
        let email = SimpleXML.textOfFirst(localName: "email", in: xml)
        let institute = SimpleXML.textOfFirst(localName: "institute", in: xml)

        logger.debug("Parsed user: firstName=\(firstName ?? "nil", privacy: .private) lastName=\(lastName ?? "nil", privacy: .private)")

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
    public func logout() async {
        await network.setToken(nil)
        KeychainStorage.clearToken()
    }
}

public struct AuthResult: Sendable {
    public var success: Bool
    public var token: String?
    public var username: String?
    public var userInfo: UserInfo?
    public var errorMessage: String?

    public init(
        success: Bool,
        token: String? = nil,
        username: String? = nil,
        userInfo: UserInfo? = nil,
        errorMessage: String? = nil
    ) {
        self.success = success
        self.token = token
        self.username = username
        self.userInfo = userInfo
        self.errorMessage = errorMessage
    }
}

public enum TokenValidation: Sendable {
    case valid(String)
    case expired
    case networkError(String)
}
