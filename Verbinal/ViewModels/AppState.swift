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

    /// Live network connectivity monitor. UI subscribes via `@Bindable` to
    /// surface "network changed; retrying…" hints when in-flight CADC
    /// requests get cut by Wi-Fi → Ethernet transitions or VPN flips.
    let networkPath = NetworkPathMonitor()

    // Headless job monitor (created on auth, destroyed on logout)
    private(set) var headlessMonitor: HeadlessMonitorModel?

    // Addon system
    let addonRegistry = AddonRegistry()
    /// Addons discovered at launch (or whenever `refreshAddons()` is called).
    /// Never nil; empty array = none of the known addons are installed.
    private(set) var installedAddons: [InstalledAddon] = []

    // MARK: - Localization

    /// UserDefaults key for the user's preferred language override.
    /// Values: "system" (follow macOS), "en", "fr".
    private static let preferredLocaleKey = "VerbinalPreferredLocale"

    /// Raw preference, stored so `@Observable` tracks mutations. Loaded
    /// from UserDefaults in `init()`. Changing it writes `AppleLanguages`
    /// into UserDefaults, which Bundle.main reads at launch to decide which
    /// lproj to load for string-catalog lookups. SwiftUI `Text` literals
    /// pick up the new language only after the next launch — live locale
    /// switching isn't supported on macOS for string resolution.
    ///
    /// Swift property observers don't fire when a class assigns to the
    /// property inside its own initializer (before super.init), so the
    /// load in `init()` safely bypasses the restart-required bookkeeping.
    var preferredLocaleIdentifier: String = "system" {
        didSet {
            guard preferredLocaleIdentifier != oldValue else { return }
            writePreferenceToDisk()
            languageChangePendingRelaunch = true
        }
    }

    /// True when the user has changed the language since launch but hasn't
    /// relaunched yet. Drives the restart banner in the Settings General tab.
    private(set) var languageChangePendingRelaunch: Bool = false

    /// Effective locale for date/number/currency formatting. Does NOT change
    /// which lproj Bundle.main reads from; that's driven by AppleLanguages
    /// and is only consulted at launch.
    var locale: Locale {
        let id = preferredLocaleIdentifier
        if id == "system" { return .current }
        return Locale(identifier: id)
    }

    /// Push the current preference into UserDefaults, including the
    /// AppleLanguages override macOS uses for bundle lookups.
    private func writePreferenceToDisk() {
        UserDefaults.standard.set(preferredLocaleIdentifier, forKey: Self.preferredLocaleKey)
        if preferredLocaleIdentifier == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([preferredLocaleIdentifier], forKey: "AppleLanguages")
        }
    }

    /// Quit-and-relaunch Verbinal so the new AppleLanguages value takes
    /// effect for bundle-resolved strings.
    func relaunch() {
        #if os(macOS)
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        #endif
    }

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

        // Route Keychain through the shared addon-family access group so every
        // first-party addon can read the CADC token without re-authing. Default
        // is unset when the entitlement isn't granted — the call is a no-op.
        KeychainStorage.configure(accessGroup: "A4ABW5VD88.codebg.verbinal.family")

        // Restore saved language preference. didSet does NOT fire for this
        // assignment (Swift rule: property observers skipped inside the
        // declaring class's own init), so no spurious "restart required".
        if let stored = UserDefaults.standard.string(forKey: Self.preferredLocaleKey) {
            self.preferredLocaleIdentifier = stored
        }

        // Begin watching for network-path changes (Wi-Fi → Ethernet, VPN flip,
        // disconnects). UI binds to this for connectivity hints.
        networkPath.start()

        // Wire NetworkClient's 401-retry interceptor: on an `unauthorized`
        // response the client invokes this handler; if it returns true the
        // client retries the original request once with the freshly-set
        // token. We do a token re-validation rather than full re-login so
        // the user isn't prompted unless the token has actually expired.
        Task { [weak self, network] in
            await network.setUnauthorizedHandler { [weak self] in
                guard let self else { return false }
                return await self.handleNetworkUnauthorized()
            }
        }
    }

    /// Called by NetworkClient when an authenticated request returned 401.
    /// Returns true if a retry of the original request is worth attempting.
    private func handleNetworkUnauthorized() async -> Bool {
        // If the stored Keychain token still validates against /whoami,
        // the 401 was a transient server hiccup — retry. Otherwise mark
        // the session expired and surface the login flow.
        let (storedToken, _) = KeychainStorage.loadToken()
        guard let token = storedToken else {
            await MainActor.run { self.handleTokenExpired() }
            return false
        }
        switch await authService.validateToken(token) {
        case .valid:
            return true
        case .expired:
            await MainActor.run { self.handleTokenExpired() }
            return false
        case .networkError:
            // Don't tear down the session on a network blip — let the
            // original request fail and the user retry.
            return false
        }
    }

    /// Re-scan installed addons. Call at app launch and whenever the user
    /// returns to the landing page (LaunchServices doesn't push updates).
    func refreshAddons() {
        installedAddons = addonRegistry.discoverInstalled()
    }

    /// Quick lookup for the notebook addon (Pi) specifically — the landing tile
    /// uses this to decide "launch it" vs "suggest installing it".
    var notebookAddon: InstalledAddon? {
        installedAddons.first { $0.manifest.addonID == "com.codebg.Verbinal.addon.notebook" }
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

    /// Attempts to re-validate a stored token. Returns true if the existing
    /// Keychain token still authenticates against `/whoami`.
    ///
    /// We deliberately don't re-login with a stored password here: the
    /// password isn't persisted (security policy — see
    /// `KeychainStorage.saveCredentials`). When the token actually expires
    /// the user must re-enter their credentials. In practice CADC tokens
    /// are long-lived, so this prompt is rare.
    private func silentReauth() async -> Bool {
        let (storedToken, storedUsername) = KeychainStorage.loadToken()
        guard let token = storedToken, storedUsername != nil else { return false }

        statusMessage = "Renewing session..."
        isLoading = true

        let validation = await authService.validateToken(token)
        switch validation {
        case .valid(let canonicalUsername):
            updateAuthState(username: canonicalUsername, userInfo: nil)
            isLoading = false
            return true
        case .expired, .networkError:
            break
        }

        // Token no longer valid — clear them
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
