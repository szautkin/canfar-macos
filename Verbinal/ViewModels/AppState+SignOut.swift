// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit
#if os(macOS)
import AppKit
#endif
#if canImport(MetricKit)
import MetricKit
#endif

/// The session's end: an expired token, signing out, and what goes with it.
extension AppState {
    /// Background-fetch the Portal image cache right after login so the Portal tab
    /// feels instant on first navigation. Honors the existing cache TTL.
    func prewarmPortalCache() {
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

    /// Pass-through to the controller for callers that detected a 401
    /// directly (e.g., `HeadlessMonitorModel.onAuthFailure`). The controller
    /// owns coalescing + silent reauth; session resources are torn down only
    /// when expiry is confirmed (`onSessionExpired`).
    func handleTokenExpired() {
        auth.handleTokenExpired()
    }

    /// Stop headless monitoring and drop user-scoped discovery models.
    /// Shared by confirmed session expiry and voluntary logout.
    func tearDownAuthenticatedSessionResources() {
        headlessMonitor?.stopMonitoring()
        headlessMonitor = nil
        imageDiscoveryCoordinator = nil
        imageDiscoveryModel = nil
        canfarImagesModel = nil
        #if os(macOS)
        remoteCompute.stopWatching()
        storageSync.signedOut()
        researchModel.transfer.storage = nil
        researchModel.storageFree = nil
        researchModel.moveTo = nil
        #endif
    }

    func logout() async {
        tearDownAuthenticatedSessionResources()

        // Cancel any in-flight prewarm so it cannot repopulate the cache after clear().
        prewarmTask?.cancel()
        prewarmTask = nil

        // Drop user-scoped cached data — settings are per-user and survive logout/login.
        portalImageCacheService.clear()

        // Tear down auth state via the controller (also cancels any
        // in-flight reauth and asks AuthService to clear the token).
        await auth.clear()
        // Voluntary logout: leave Portal/Storage without re-entry intent.
        pendingModeAfterLogin = nil
        leaveAuthGatedModesIfNeeded(rememberForRelogin: false)
        statusMessage = String(localized: "Logged out")
    }
}
