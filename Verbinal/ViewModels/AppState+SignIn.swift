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

/// Signing in, and what the app starts for the person once they are: their sessions, jobs, images and storage.
extension AppState {
    /// Called on app launch — delegates to the controller. Registry
    /// endpoint resolution is fired off first but never awaited: launch
    /// and auth always proceed on the endpoints captured at init.
    func initialize() async {
        Task { [endpointRegistry] in
            await endpointRegistry.refreshIfStale()
        }
        await auth.validateStoredToken()
    }

    /// True when sign-in is parked waiting for connectivity to return.
    /// Drives the offline hint + manual retry on the landing screen.
    var authAwaitingConnectivity: Bool { auth.awaitingConnectivity }

    /// The launch check has not answered yet, or the session is being
    /// checked or renewed. Every outcome of the check leaves a status
    /// message, so signed out with none means it is still to come. The iOS
    /// shell's Portal and Compute say they are checking then, not locked (plan 49).
    var isCheckingSignIn: Bool {
        auth.activity != .idle || (!auth.isAuthenticated && auth.statusMessage.isEmpty)
    }

    /// Called by the view layer on every network-path change. Resumes a
    /// connectivity-deferred sign-in once the path is satisfied; no-op
    /// otherwise (guards live in the controller).
    func networkPathDidChange() {
        guard networkPath.connectivity == .satisfied else { return }
        Task { await auth.retryValidationIfConnectivityRestored() }
    }

    /// The app came back to the front: a sign-in not confirmed for a while
    /// is checked, so a session that ended meanwhile asks to sign in now.
    func appDidBecomeActive() {
        Task { await auth.recheckIfStale() }
    }

    /// Pass-through used by `LoginSheet` after a successful login. Forwards
    /// to the controller, which fires `onAuthenticated` to wire up
    /// navigation / headless monitor / portal-cache prewarm here.
    func updateAuthState(username: String, userInfo: UserInfo?) {
        auth.apply(username: username, userInfo: userInfo)
    }

    /// Hook fired by `AuthLifecycleController.onAuthenticated`. AppState
    /// owns the cross-module orchestration that follows a successful login:
    /// jump to a pending navigation target, start the headless-job monitor,
    /// prewarm the Portal image cache.
    func afterAuthenticated() {
        if let pending = pendingModeAfterLogin {
            // Only honor return-intent while still on Landing. If the user
            // already moved to a free module, do not steal them back.
            if currentMode == .landing {
                navigateTo(pending)
            }
            pendingModeAfterLogin = nil
        }

        // Code runs still out when watching stopped — a sign-out, a quit — are looked at again (plan 30 K).
        Task { await remoteCompute.resumeWatching() }
        #if os(macOS)
        // Records kept before their details came from the archive are
        // brought up to it once, in the background (plan 17 G3).
        Task { await researchRecordRepair.run() }
        // Verbinal's data in VOSpace: at once, in the background (plan 34 V).
        startStorageSync()
        #endif

        // Idempotent: silent reauth no longer fires this hook, but guard
        // against any future double-apply so we don't stack monitors.
        guard headlessMonitor == nil else {
            prewarmPortalCache()
            return
        }

        let monitor = HeadlessMonitorModel(headlessService: headlessService, history: jobHistory)
        monitor.onAuthFailure = { [weak self] in
            Task { @MainActor in
                self?.auth.handleTokenExpired()
            }
        }
        headlessMonitor = monitor
        monitor.startMonitoring()

        #if os(macOS)
        // Image discovery — manifest cache + probe orchestration (Mac only,
        // plan 47 0.9). Created lazily here because the coordinator needs a real
        // username for VOSpace IO. Same lifetime as the headless
        // monitor (set up here, torn down on logout).
        let cacheDir = JSONManifestStore.defaultDirectory()
        let store = JSONManifestStore(directory: cacheDir)
        // Types lookup so the coordinator can pick in-target vs
        // inspector strategy per image. Best-effort: a transient
        // catalogue fetch failure means we fall back to in-target,
        // which is the prior single-strategy behaviour.
        let typesLookup: @Sendable (String) async -> [String]? = { [weak self] id in
            guard let raws = try? await self?.catalogueImages() else { return nil }
            return raws.first(where: { $0.id == id })?.types
        }

        // Bridge the Image Discovery settings service into the
        // coordinator via two closures. The coordinator stays
        // unaware of UI / persistence concerns; the closures hop
        // to MainActor on demand to read the current settings
        // snapshot. Reading on every probe (not caching) means
        // Settings changes take effect on the next attempt.
        let settingsService = imageDiscoverySettings
        let authProvider: @Sendable () async -> String? = { [weak self] in
            guard let self else { return nil }
            return await MainActor.run { self.imageDiscoverySettings.currentAuthHeader() }
        }
        // Keep `settingsService` referenced inside the resolver so
        // it doesn't get optimised away — the coordinator captures
        // it through this closure.
        _ = settingsService
        let inspectorResolver: @Sendable () async -> String = { [weak self] in
            guard let self else { return ImageDiscoverySettings.defaultInspectorImage }
            return await MainActor.run { self.imageDiscoverySettings.settings.inspectorImage }
        }

        let coord = ImageDiscoveryCoordinator(
            store: store,
            headless: headlessService,
            vospace: VOSpaceBrowserService(network: network, endpoints: endpoints),
            username: username,
            imageTypesLookup: typesLookup,
            registryAuthProvider: authProvider,
            inspectorImageResolver: inspectorResolver,
            recordJob: { [weak self] job in await self?.jobHistory.record(job) }
        )
        imageDiscoveryCoordinator = coord
        imageDiscoveryModel = ImageDiscoveryModel(coordinator: coord)
        // Probe failures from before the history kept them (plan 15 F7).
        Task { [weak self] in
            let records = await coord.failedProbeRecords()
            self?.jobHistory.recordMissingOnce(records, key: "jobHistory.seededFromProbeFailures")
        }
        canfarImagesModel = CanfarImagesModel(
            imageService: imageService,
            coordinator: coord,
            recentLaunchStore: recentLaunchStore,
            portalSettingsService: portalSettingsService,
            userImages: userImages,
            username: username
        )
        #endif

        prewarmPortalCache()
    }
}
