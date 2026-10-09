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

    /// Why the sign-in sheet asks, when a session ended rather than at a
    /// first sign-in (plan 34 A); nil once signed in.
    private(set) var signInReason: String?

    /// The renewal under way: every caller shares it, so many 401s at once
    /// sign in once (plan 34 A).
    private var renewal: Task<Renewal, Never>?
    /// When a renewal last signed in: a 401 just after it belonged to the
    /// old token, and is retried as it is rather than signing in again.
    private var signedInAt: Date?
    private static let signedInRecently: TimeInterval = 30
    /// The clock, for tests.
    var now: () -> Date = Date.init

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

    /// What a renewal came to (plan 34 A).
    enum Renewal: Equatable, Sendable {
        /// Signed in again, or the stored sign-in still holds.
        case renewed
        /// Neither could be established: the stored sign-in is kept.
        case offline
        /// The person must sign in.
        case ended
    }

    /// Where a renewal starts: the stored token first, or at once a sign-in
    /// with the stored password.
    enum RenewalStart: Sendable {
        case storedToken
        /// CADC said the stored token has expired.
        case expiredToken
        /// CADC accepts the stored token, but a service refused it.
        case refusedToken
    }

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
            await renew(from: .expiredToken)
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
                await renew(from: .expiredToken)
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
        self.signInReason = nil
        let displayName = [userInfo?.firstName, userInfo?.lastName]
            .compactMap { $0 }
            .joined(separator: " ")
        self.statusMessage = String(localized: "Welcome, \(displayName.isEmpty ? username : displayName)")
        if !wasAuthenticated {
            onAuthenticated?()
            events.notify(.signedIn(username))
        }
    }

    /// Called when any service detects a 401 mid-session. Keeps
    /// `isAuthenticated` true until the renewal confirms the end, so
    /// Portal/Storage chrome does not flash the login wall mid-flight.
    func handleTokenExpired() {
        guard isAuthenticated else { return }
        Task { await renew() }
    }

    /// `NetworkClient` 401-interceptor entry point: whether the request is
    /// worth one more try (plan 34 A). Every 401 goes through the one
    /// renewal, so many at once check the token and sign in once.
    ///
    /// - A first 401: the stored token is checked with `/whoami`. Still
    ///   good — retry, with the token stamped again. Expired — the request
    ///   waits for a sign-in with the stored password, then is retried.
    /// - A second 401, on a token CADC accepts: one fresh sign-in with the
    ///   stored password, then one more try. Without a stored password the
    ///   request fails and the session stays: one service's refusal never
    ///   ends it.
    /// - The renewal's own requests are never held for it.
    func handleNetworkUnauthorized(_ attempt: NetworkClient.UnauthorizedAttempt = .first) async -> Bool {
        guard !Renewing.now else { return false }
        switch attempt {
        case .first:
            return await renew() == .renewed
        case .again:
            let (_, password) = KeychainStorage.loadCredentials()
            guard let password, !password.isEmpty else { return false }
            return await renew(from: .refusedToken) == .renewed
        }
    }

    /// The one renewal (plan 34 A): single-flight — a caller while one is
    /// under way waits for it — and a renewal just made counts for the 401s
    /// that follow it. The 401 handler, the launch check and the
    /// connectivity retry all come here.
    @discardableResult
    func renew(from start: RenewalStart = .storedToken) async -> Renewal {
        if let renewal { return await renewal.value }
        if let signedInAt, now().timeIntervalSince(signedInAt) < Self.signedInRecently { return .renewed }
        let wasAuthenticated = isAuthenticated
        let task = Task { [weak self] () -> Renewal in
            guard let self else { return .ended }
            let outcome = await Renewing.$now.withValue(true) { await self.silentReauth(from: start) }
            self.settle(outcome, wasAuthenticated: wasAuthenticated)
            return outcome
        }
        renewal = task
        let outcome = await task.value
        renewal = nil
        return outcome
    }

    /// What a renewal's outcome means for the person, said once.
    private func settle(_ outcome: Renewal, wasAuthenticated: Bool) {
        switch outcome {
        case .renewed:
            awaitingConnectivity = false
        case .offline:
            // Keep the session live; the connectivity retry soft-validates.
            awaitingConnectivity = true
            statusMessage = wasAuthenticated
                ? String(localized: "You appear to be offline. Verbinal will reconnect automatically.")
                : String(localized: "You're offline. Verbinal will sign you in when the connection returns.")
        case .ended:
            // `silentReauth` already cleared the auth state.
            awaitingConnectivity = false
            statusMessage = String(localized: "Session expired. Please log in again.")
            if wasAuthenticated {
                signInReason = String(localized: "Your CADC session ended. Sign in to continue.")
                onSessionExpired?()
            }
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

    private func silentReauth(from start: RenewalStart) async -> Renewal {
        let (storedToken, storedUsername) = KeychainStorage.loadToken()
        guard let token = storedToken, let storedUser = storedUsername else {
            username = ""
            userInfo = nil
            isAuthenticated = false
            decisions.record(.signInLost, "the sign-in ended: no stored sign-in to renew, so the person must sign in")
            return .ended
        }

        // Definitely offline — nothing to gain from a doomed request, and
        // the caller must not mistake the failure for real expiry.
        guard connectivityProvider() != .unsatisfied else {
            decisions.record(.signInKept, "the stored sign-in was kept unchecked: this Mac has no network")
            return .offline
        }

        // Stage 1: try the stored token — unless the caller knows it is gone.
        // Quiet: a 401 on a good token changes nothing the person sees.
        if start == .storedToken {
            switch await authService.validateToken(token) {
            case .valid(let canonical):
                if !isAuthenticated || canonical != username { apply(username: canonical, userInfo: nil) }
                return .renewed
            case .networkError(let why):
                // Don't burn the password on a transient network blip —
                // bail out, the connectivity retry path resumes the session.
                decisions.record(.signInKept, "the stored sign-in was kept unchecked: CADC could not be reached (\(why))")
                return .offline
            case .expired:
                break
            }
        }

        // Stage 2: token's gone. If the user said Remember-me, the
        // password is in the Keychain; try a fresh login.
        let (_, storedPassword) = KeychainStorage.loadCredentials()
        if let password = storedPassword, !password.isEmpty {
            statusMessage = String(localized: "Re-authenticating…")
            isLoading = true
            let result = await authService.login(
                username: storedUser,
                password: password,
                rememberMe: true
            )
            if result.success {
                signedInAt = now()
                apply(
                    username: result.username ?? storedUser,
                    userInfo: result.userInfo
                )
                isLoading = false
                decisions.record(.signedInAgain, start == .refusedToken
                    ? "signed in again with the stored password: a service refused the sign-in CADC still accepted"
                    : "signed in again with the stored password: the sign-in had expired")
                return .renewed
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
        return .ended
    }

    /// Tear the session down (called by `AppState.logout`). Cancels any
    /// in-flight reauth and asks the AuthService to clear the token.
    func clear() async {
        renewal?.cancel()
        renewal = nil
        signedInAt = nil
        signInReason = nil
        await authService.logout()
        username = ""
        userInfo = nil
        isAuthenticated = false
        statusMessage = String(localized: "Please log in")
        events.notify(.signedOut)
    }
}

/// Whether the current task is the renewal itself: its own requests (the
/// sign-in's user details) must not wait for it.
private enum Renewing {
    @TaskLocal static var now = false
}
