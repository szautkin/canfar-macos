// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// Owns the auth-lifecycle slice of `AppState`: token validation, silent
/// reauth, token-expiry coalescing, and the `username` / `isAuthenticated`
/// / `userInfo` / `statusMessage` / `isLoading` published state.
///
/// The controller is intentionally narrow:
///  • It does *not* know about navigation, the headless monitor, the
///    Portal cache, or sheet presentation. Those live on `AppState` and
///    react to `onAuthenticated` / `onSessionExpired` callbacks.
///  • It uses only `AuthService` + `KeychainStorage` (both injectable for
///    tests via the `AuthService` parameter and the in-process Keychain),
///    so it can be unit-tested without spinning up the entire app.
///
/// The original `AppState.handleTokenExpired` / `silentReauth` /
/// `initialize` paths now live here. `AppState` keeps thin pass-throughs
/// for backwards compatibility with consumers that read `appState.username`
/// or call `appState.handleTokenExpired()` directly.
@Observable
@MainActor
final class AuthLifecycleController {
    private let authService: AuthService

    // MARK: Published state

    private(set) var isAuthenticated: Bool = false
    var isLoading: Bool = false
    private(set) var username: String = ""
    private(set) var userInfo: UserInfo?
    var statusMessage: String = ""

    /// Single in-flight reauth task. Coalesces concurrent 401s so two
    /// races don't both run `validateToken`.
    private var tokenExpiryTask: Task<Void, Never>?

    // MARK: Hooks

    /// Called immediately after the controller's state transitions to
    /// authenticated (login OR successful silent reauth). `AppState`
    /// hooks navigation, headless monitor, and Portal-cache prewarm here.
    var onAuthenticated: (@MainActor () -> Void)?
    /// Called when the controller has decided the session is gone and
    /// the user must re-enter credentials. `AppState` shows the login sheet.
    var onSessionExpired: (@MainActor () -> Void)?

    init(authService: AuthService) {
        self.authService = authService
    }

    // MARK: Lifecycle

    /// Validate the stored Keychain token at app launch.
    func validateStoredToken() async {
        let (storedToken, storedUsername) = KeychainStorage.loadToken()

        guard let token = storedToken, !token.isEmpty else {
            statusMessage = "Please log in"
            return
        }

        isLoading = true
        statusMessage = "Validating session..."

        switch await authService.validateToken(token) {
        case .valid(let validatedUsername):
            let name = storedUsername ?? validatedUsername
            let info = await authService.getUserInfo(username: name)
            apply(username: name, userInfo: info)
        case .expired:
            if await silentReauth() {
                isLoading = false
                return
            }
            statusMessage = "Session expired. Please log in again."
        case .networkError(let message):
            statusMessage = "Cannot connect: \(message). Please try again."
        }

        isLoading = false
    }

    /// Mark the session authenticated and fire `onAuthenticated`. Called
    /// by both successful login and silent reauth paths.
    func apply(username: String, userInfo: UserInfo?) {
        self.username = username
        self.userInfo = userInfo
        self.isAuthenticated = true
        let displayName = [userInfo?.firstName, userInfo?.lastName]
            .compactMap { $0 }
            .joined(separator: " ")
        self.statusMessage = "Welcome, \(displayName.isEmpty ? username : displayName)"
        onAuthenticated?()
    }

    /// Called when any service detects a 401 mid-session. Coalesces
    /// concurrent expirations so two races don't both run reauth.
    func handleTokenExpired() {
        guard isAuthenticated else { return }
        if let task = tokenExpiryTask, !task.isCancelled { return }
        isAuthenticated = false

        tokenExpiryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.tokenExpiryTask = nil }
            if await self.silentReauth() { return }
            self.statusMessage = "Session expired. Please log in again."
            self.onSessionExpired?()
        }
    }

    /// `NetworkClient` 401-interceptor entry point. Returns `true` if the
    /// stored token still validates against `/whoami` (so the original
    /// request is worth retrying once); `false` if the session is gone or
    /// the network is unreachable.
    func handleNetworkUnauthorized() async -> Bool {
        let (storedToken, _) = KeychainStorage.loadToken()
        guard let token = storedToken else {
            handleTokenExpired()
            return false
        }
        switch await authService.validateToken(token) {
        case .valid:
            return true
        case .expired:
            handleTokenExpired()
            return false
        case .networkError:
            return false
        }
    }

    /// Try to renew the session using a stored Keychain token. We do *not*
    /// re-login with a stored password — the password isn't persisted by
    /// policy (see `KeychainStorage.saveCredentials`). When the token is
    /// truly expired the user must re-enter credentials.
    private func silentReauth() async -> Bool {
        let (storedToken, storedUsername) = KeychainStorage.loadToken()
        guard let token = storedToken, storedUsername != nil else { return false }

        statusMessage = "Renewing session..."
        isLoading = true

        let validation = await authService.validateToken(token)
        switch validation {
        case .valid(let canonical):
            apply(username: canonical, userInfo: nil)
            isLoading = false
            return true
        case .expired, .networkError:
            break
        }

        KeychainStorage.clearToken()
        username = ""
        userInfo = nil
        isAuthenticated = false
        isLoading = false
        return false
    }

    /// Tear the session down (called by `AppState.logout`). Cancels any
    /// in-flight reauth and asks the AuthService to clear the token.
    func clear() async {
        tokenExpiryTask?.cancel()
        tokenExpiryTask = nil
        await authService.logout()
        username = ""
        userInfo = nil
        isAuthenticated = false
        statusMessage = "Please log in"
    }
}
