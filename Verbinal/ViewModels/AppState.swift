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
    let recentLaunchStore = RecentLaunchStore()

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
            KeychainStorage.clearToken()
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
        self.statusMessage = "Welcome, \(userInfo?.firstName ?? username)"
    }

    func logout() async {
        await authService.logout()
        isAuthenticated = false
        username = ""
        userInfo = nil
        statusMessage = "Logged out"
    }
}
