// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

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

    // Auth state
    var isAuthenticated = false
    var isLoading = false
    var username = ""
    var statusMessage = ""
    var userInfo: UserInfo?

    // UI state
    var showLoginSheet = false

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

        // Start headless job monitoring
        let monitor = HeadlessMonitorModel(headlessService: headlessService)
        monitor.onAuthFailure = { [weak self] in
            Task { @MainActor in
                self?.handleTokenExpired()
            }
        }
        headlessMonitor = monitor
        monitor.startMonitoring()
    }

    /// Called when any service detects a 401 — token has expired mid-session.
    /// Tries silent re-auth if credentials are stored, otherwise shows login sheet.
    func handleTokenExpired() {
        guard isAuthenticated else { return }
        headlessMonitor?.stopMonitoring()
        headlessMonitor = nil
        isAuthenticated = false

        Task {
            if await silentReauth() { return }
            // Silent re-auth failed — prompt user
            statusMessage = "Session expired. Please log in again."
            showLoginSheet = true
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

        await authService.logout()
        isAuthenticated = false
        username = ""
        userInfo = nil
        statusMessage = "Logged out"
    }
}
