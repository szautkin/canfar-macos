// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

enum AppMode: Equatable {
    case landing
    case search
    case portal
    case research
    case storage
    case fitsViewer
}

@Observable
@MainActor
final class AppState {
    let network: NetworkClient
    let endpoints: APIEndpoints

    // Services (all share the same NetworkClient for token injection)
    let authService: AuthService
    let sessionService: SessionService
    let imageService: ImageService
    let platformService: PlatformService
    let storageService: StorageService
    let headlessService: HeadlessService
    let recentLaunchStore = RecentLaunchStore()
    let portalSettingsService = PortalSettingsService()
    let portalImageCacheService = PortalImageCacheService()

    // Headless job monitor (created on auth, destroyed on logout)
    private(set) var headlessMonitor: HeadlessMonitorModel?

    init() {
        let network = NetworkClient()
        let endpoints = APIEndpoints()
        self.network = network
        self.endpoints = endpoints
        self.authService = AuthService(network: network, endpoints: endpoints)
        self.sessionService = SessionService(network: network, endpoints: endpoints)
        self.imageService = ImageService(network: network, endpoints: endpoints)
        self.platformService = PlatformService(network: network, endpoints: endpoints)
        self.storageService = StorageService(network: network, endpoints: endpoints)
        self.headlessService = HeadlessService(network: network, endpoints: endpoints)
    }

    // Navigation state
    var currentMode: AppMode = .landing
    var pendingModeAfterLogin: AppMode?
    private(set) var navigationStack: [AppMode] = []
    var canGoBack: Bool { !navigationStack.isEmpty }

    func navigateTo(_ mode: AppMode) {
        navigationStack.append(currentMode)
        currentMode = mode
    }

    func navigateBack() {
        navigationStack.removeAll()
        currentMode = .landing
    }

    // Cross-module actions
    var pendingFITSURL: URL?

    /// Pending sky coordinates from FITS viewer crosshair → Search tab.
    /// Includes a unique `id` so `.task(id:)` always re-fires, even if the
    /// same sky position is searched twice in a row.
    struct PendingCoordinate: Equatable {
        let id = UUID()
        let ra: Double
        let dec: Double
    }
    var pendingSearchCoordinate: PendingCoordinate?

    enum AppAction {
        case openFITS(url: URL)
        case searchCoordinates(ra: Double, dec: Double)
    }

    func dispatch(_ action: AppAction) {
        switch action {
        case .openFITS(let url):
            pendingFITSURL = url
            navigateTo(.fitsViewer)
        case .searchCoordinates(let ra, let dec):
            pendingSearchCoordinate = PendingCoordinate(ra: ra, dec: dec)
            navigateTo(.search)
        }
    }

    // Auth state
    var isAuthenticated = false
    var isLoading = false
    var username = ""
    var statusMessage = ""
    var userInfo: UserInfo?

    // UI state

    /// One-at-a-time sheet presentation. SwiftUI's `.sheet` modifier only shows
    /// one sheet per view hierarchy — using a single item-based sheet with this
    /// enum prevents silent sheet drops when two triggers fire in the same tick
    /// (e.g. token-expiry login prompt while export is open).
    enum ActiveSheet: String, Identifiable {
        case login, about, export
        var id: String { rawValue }
    }
    var activeSheet: ActiveSheet?

    /// True if the login sheet should be shown. Convenience for call sites that
    /// only need to know about the login sheet specifically.
    var showLoginSheet: Bool {
        get { activeSheet == .login }
        set {
            if newValue {
                activeSheet = .login
            } else if activeSheet == .login {
                activeSheet = nil
            }
        }
    }

    /// Called on app launch — checks Keychain for a stored token.
    func initialize() async {
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
            updateAuthState(username: name, userInfo: info)
        case .expired:
            // Try silent re-auth with stored password before prompting
            if await silentReauth() {
                isLoading = false
                return
            }
            statusMessage = "Session expired. Please log in again."
        case .networkError(let message):
            // Keep the token — just can't reach the server right now
            statusMessage = "Cannot connect: \(message). Please try again."
        }

        isLoading = false
    }

    func updateAuthState(username: String, userInfo: UserInfo?) {
        self.username = username
        self.userInfo = userInfo
        self.isAuthenticated = true
        let displayName = [userInfo?.firstName, userInfo?.lastName]
            .compactMap { $0 }
            .joined(separator: " ")
        self.statusMessage = "Welcome, \(displayName.isEmpty ? username : displayName)"

        // Navigate to pending mode after login (e.g. Portal, Storage)
        if let pending = pendingModeAfterLogin {
            navigateTo(pending)
            pendingModeAfterLogin = nil
        }

        // Start headless job monitoring
        let monitor = HeadlessMonitorModel(headlessService: headlessService)
        monitor.onAuthFailure = { [weak self] in
            Task { @MainActor in
                self?.handleTokenExpired()
            }
        }
        headlessMonitor = monitor
        monitor.startMonitoring()

        // Warm the Portal image cache in the background so the Portal tab feels instant
        // on first navigation. If the cache is already fresh, this is a no-op.
        prewarmPortalCache()
    }

    /// Active prewarm task — cancelled on logout so an in-flight fetch cannot
    /// repopulate the cache with the previous user's data after `clear()` runs.
    private var prewarmTask: Task<Void, Never>?

    /// Background-fetch the Portal image cache right after login so the Portal tab
    /// feels instant on first navigation. Honors the existing cache TTL.
    private func prewarmPortalCache() {
        let user = username
        guard !user.isEmpty else { return }
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (_, wasCached) = try await self.portalImageCacheService.loadOrFetch(
                    username: user,
                    imageService: self.imageService
                )
                try Task.checkCancellation()
                if wasCached && self.portalImageCacheService.isStale {
                    _ = try? await self.portalImageCacheService.fetchFresh(
                        username: user,
                        imageService: self.imageService
                    )
                }
            } catch {
                // Silent — SessionLaunchModel will retry when the user opens Portal.
            }
        }
    }

    /// Active token-expiry handler. Guarded so two simultaneous 401s don't
    /// race two concurrent re-auth attempts and double-fire updateAuthState.
    private var tokenExpiryTask: Task<Void, Never>?

    /// Called when any service detects a 401 — token has expired mid-session.
    /// Tries silent re-auth if credentials are stored, otherwise shows login sheet.
    func handleTokenExpired() {
        guard isAuthenticated else { return }
        // Coalesce concurrent 401s: if a reauth task is already running, keep it.
        if let task = tokenExpiryTask, !task.isCancelled {
            return
        }
        headlessMonitor?.stopMonitoring()
        headlessMonitor = nil
        isAuthenticated = false

        tokenExpiryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.tokenExpiryTask = nil }
            if await self.silentReauth() { return }
            // Silent re-auth failed — prompt user
            self.statusMessage = "Session expired. Please log in again."
            self.showLoginSheet = true
        }
    }

    /// Attempts to re-authenticate using stored Keychain credentials.
    /// Returns true on success.
    private func silentReauth() async -> Bool {
        let (storedUsername, storedPassword) = KeychainStorage.loadCredentials()
        guard let user = storedUsername, let pass = storedPassword else { return false }

        statusMessage = "Renewing session..."
        isLoading = true

        let result = await authService.login(username: user, password: pass, rememberMe: true)

        if result.success {
            updateAuthState(
                username: result.username ?? user,
                userInfo: result.userInfo
            )
            isLoading = false
            return true
        }

        // Credentials no longer valid — clear them
        KeychainStorage.clearToken()
        username = ""
        userInfo = nil
        isLoading = false
        return false
    }

    func logout() async {
        headlessMonitor?.stopMonitoring()
        headlessMonitor = nil

        // Cancel any in-flight prewarm so it cannot repopulate the cache after clear().
        prewarmTask?.cancel()
        prewarmTask = nil

        // Cancel any pending re-auth so it cannot surface a stale login prompt after logout.
        tokenExpiryTask?.cancel()
        tokenExpiryTask = nil

        // Drop user-scoped cached data — settings are per-user and survive logout/login.
        portalImageCacheService.clear()

        await authService.logout()
        isAuthenticated = false
        username = ""
        userInfo = nil
        statusMessage = "Logged out"
    }
}
