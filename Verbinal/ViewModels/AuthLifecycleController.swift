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

    /// True when a validation was skipped or failed for network reasons and
    /// should re-run automatically when connectivity returns. Consumed (set
    /// to false) at the top of each retry so one path change triggers at
    /// most one attempt; only a genuine offline outcome re-arms it.
    private(set) var awaitingConnectivity = false

    /// Single in-flight reauth task. Coalesces concurrent 401s so two
    /// races don't both run `validateToken`.
    private var tokenExpiryTask: Task<Void, Never>?

    /// Injected connectivity probe. `AppState` wires this to its
    /// `NetworkPathMonitor`; tests inject a stub. The `.unknown` default
    /// never short-circuits — we only skip network calls on a *definite*
    /// offline signal, so untested/unwired paths behave exactly as before.
    var connectivityProvider: @MainActor () -> NetworkPathMonitor.Connectivity = { .unknown }

    // MARK: Hooks

    /// Called when the controller transitions from signed-out to
    /// authenticated (cold login / launch validate). Silent reauth that
    /// refreshes an already-live session does **not** fire this — so
    /// `AppState` does not rebuild monitors mid-flight.
    var onAuthenticated: (@MainActor () -> Void)?
    /// Called when the controller has decided the session is gone and
    /// the user must re-enter credentials. `AppState` leaves Portal /
    /// Storage and shows the login sheet.
    var onSessionExpired: (@MainActor () -> Void)?

    init(authService: AuthService) {
        self.authService = authService
    }

    private enum ReauthOutcome { case success, sessionExpired, offline }

    // MARK: Lifecycle

    /// Validate the stored Keychain token at app launch.
    func validateStoredToken() async {
        let (storedToken, storedUsername) = KeychainStorage.loadToken()

        guard let token = storedToken, !token.isEmpty else {
            statusMessage = String(localized: "Please log in")
            return
        }

        // Definitely offline — don't fire a doomed request that would hold
        // the validating state (toolbar spinner, locked tiles) until the
        // request timeout. The connectivity-change retry path picks this
        // up automatically.
        guard connectivityProvider() != .unsatisfied else {
            awaitingConnectivity = true
            statusMessage = String(localized: "You're offline. Verbinal will sign you in when the connection returns.")
            return
        }

        isLoading = true
        statusMessage = String(localized: "Validating session...")

        switch await authService.validateToken(token) {
        case .valid(let validatedUsername):
            awaitingConnectivity = false
            let name = storedUsername ?? validatedUsername
            let info = await authService.getUserInfo(username: name)
            apply(username: name, userInfo: info)
        case .expired:
            switch await silentReauth() {
            case .success:
                isLoading = false
                return
            case .offline:
                awaitingConnectivity = true
                statusMessage = String(localized: "You're offline. Verbinal will sign you in when the connection returns.")
            case .sessionExpired:
                awaitingConnectivity = false
                statusMessage = String(localized: "Session expired. Please log in again.")
            }
        case .networkError(let message):
            awaitingConnectivity = true
            statusMessage = String(localized: "Cannot connect: \(message). Verbinal will retry when the network returns.")
        }

        isLoading = false
    }

    /// Re-run the stored-token validation after a network-path change.
    /// Call on every path transition; the guards make it a no-op unless a
    /// previous validation was deferred/failed for network reasons and the
    /// path is now satisfied. `awaitingConnectivity` is consumed *before*
    /// the attempt so a failure re-arms it rather than looping.
    ///
    /// Mid-session offline (still authenticated) soft-validates the token;
    /// cold launch / signed-out deferral runs full `validateStoredToken`.
    func retryValidationIfConnectivityRestored() async {
        guard awaitingConnectivity, !isLoading,
              connectivityProvider() == .satisfied else { return }
        awaitingConnectivity = false
        if isAuthenticated {
            let (storedToken, _) = KeychainStorage.loadToken()
            guard let token = storedToken else {
                handleTokenExpired()
                return
            }
            switch await authService.validateToken(token) {
            case .valid:
                return
            case .expired:
                handleTokenExpired()
            case .networkError:
                awaitingConnectivity = true
            }
        } else {
            await validateStoredToken()
        }
    }

    /// Mark the session authenticated. Fires `onAuthenticated` only on the
    /// signed-out → signed-in transition so silent reauth does not rebuild
    /// AppState session resources.
    /// Signing in and out, as they happen — for the session log (plan 23).
    enum Event: Sendable {
        case signedIn(String)
        case signedOut
    }
    nonisolated let events = Observers<Event>()

    func apply(username: String, userInfo: UserInfo?) {
        let wasAuthenticated = isAuthenticated
        self.username = username
        self.userInfo = userInfo
        self.isAuthenticated = true
        let displayName = [userInfo?.firstName, userInfo?.lastName]
            .compactMap { $0 }
            .joined(separator: " ")
        self.statusMessage = String(localized: "Welcome, \(displayName.isEmpty ? username : displayName)")
        if !wasAuthenticated {
            onAuthenticated?()
            events.notify(.signedIn(username))
        }
    }

    /// Called when any service detects a 401 mid-session. Coalesces
    /// concurrent expirations so two races don't both run reauth.
    /// Keeps `isAuthenticated` true until silent reauth confirms expiry
    /// so Portal/Storage chrome does not flash the login wall mid-flight.
    func handleTokenExpired() {
        guard isAuthenticated else { return }
        if let task = tokenExpiryTask, !task.isCancelled { return }

        tokenExpiryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.tokenExpiryTask = nil }
            switch await self.silentReauth() {
            case .success:
                return
            case .offline:
                // Keep the session live; connectivity retry soft-validates.
                self.awaitingConnectivity = true
                self.statusMessage = String(localized: "You appear to be offline. Verbinal will reconnect automatically.")
            case .sessionExpired:
                // `silentReauth` already cleared auth state.
                self.statusMessage = String(localized: "Session expired. Please log in again.")
                self.onSessionExpired?()
            }
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

    /// Try to renew the session without prompting the user.
    ///
    /// Two-stage: first the stored token (cheap — one /whoami call).
    /// If that comes back expired AND the user opted into Remember-me
    /// (so we have a password in the Keychain), retry with a full
    /// login(username, password) — that also writes a fresh token
    /// back to the Keychain on success, so subsequent launches are
    /// fast again.
    ///
    /// Falls through to the strict failure path (clear Keychain,
    /// surface "session expired") only when we have neither a valid
    /// token NOR usable stored credentials. `.offline` means neither
    /// success nor failure could be established — callers must keep the
    /// stored credentials and defer to the connectivity retry path.
    /// Where the renewal's decisions are recorded, each with its reason
    /// (plan 23 A).
    private let decisions: DecisionLog = .shared

    private func silentReauth() async -> ReauthOutcome {
        let (storedToken, storedUsername) = KeychainStorage.loadToken()
        guard let token = storedToken, let storedUser = storedUsername else {
            username = ""
            userInfo = nil
            isAuthenticated = false
            decisions.record(.signInLost, "the sign-in ended: no stored sign-in to renew, so the person must sign in")
            return .sessionExpired
        }

        // Definitely offline — nothing to gain from a doomed request, and
        // the caller must not mistake the failure for real expiry.
        guard connectivityProvider() != .unsatisfied else {
            decisions.record(.signInKept, "the stored sign-in was kept unchecked: this Mac has no network")
            return .offline
        }

        statusMessage = String(localized: "Renewing session...")
        isLoading = true

        // Stage 1: try the stored token.
        switch await authService.validateToken(token) {
        case .valid(let canonical):
            apply(username: canonical, userInfo: nil)
            isLoading = false
            return .success
        case .networkError(let why):
            // Don't burn the password on a transient network blip —
            // bail out, the connectivity retry path resumes the session.
            isLoading = false
            decisions.record(.signInKept, "the stored sign-in was kept unchecked: CADC could not be reached (\(why))")
            return .offline
        case .expired:
            break
        }

        // Stage 2: token's gone. If the user said Remember-me, the
        // password is in the Keychain; try a fresh login.
        let (_, storedPassword) = KeychainStorage.loadCredentials()
        if let password = storedPassword, !password.isEmpty {
            statusMessage = String(localized: "Re-authenticating…")
            let result = await authService.login(
                username: storedUser,
                password: password,
                rememberMe: true
            )
            if result.success {
                apply(
                    username: result.username ?? storedUser,
                    userInfo: result.userInfo
                )
                isLoading = false
                decisions.record(.signedInAgain, "signed in again with the stored password: the sign-in had expired")
                return .success
            }
            // Transient network / 5xx — keep credentials; connectivity
            // retry (or the next user action) will try again.
            if !result.isCredentialRejection {
                isLoading = false
                decisions.record(.signInKept, "the stored password was kept: CADC did not answer the sign-in (\(result.errorMessage ?? "no reason given"))")
                return .offline
            }
            // Password rejected by CADC — likely user changed it.
            // Clear it so we don't keep retrying with a known-bad
            // password every launch.
            KeychainStorage.clearToken()
            decisions.record(.signInLost, "the sign-in ended: CADC refused the stored password, so it was cleared and the person must sign in")
        } else {
            KeychainStorage.clearToken()
            decisions.record(.signInLost, "the sign-in ended: it expired and no password is stored, so the person must sign in")
        }

        username = ""
        userInfo = nil
        isAuthenticated = false
        isLoading = false
        return .sessionExpired
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
        statusMessage = String(localized: "Please log in")
        events.notify(.signedOut)
    }
}
