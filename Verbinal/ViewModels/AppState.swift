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
    /// User-configurable defaults for the Image Discovery feature:
    /// registry credentials (for the `x-skaha-registry-auth` header
    /// on probe jobs) and the inspector-mode host image override.
    /// Wired into `ImageDiscoveryCoordinator` via closures so the
    /// coordinator stays unaware of UI / persistence concerns.
    let imageDiscoverySettings = ImageDiscoverySettingsService()

    /// Live network connectivity monitor. UI subscribes via `@Bindable` to
    /// surface "network changed; retrying…" hints when in-flight CADC
    /// requests get cut by Wi-Fi → Ethernet transitions or VPN flips.
    let networkPath = NetworkPathMonitor()

    /// MCP server lifecycle. Off by default — the user opts in via
    /// Settings ▸ Agents. Read tools land in P4; until then the bridge
    /// answers tools/list with an empty manifest.
    let agentsService = AgentsService()

    // Headless job monitor (created on auth, destroyed on logout)
    private(set) var headlessMonitor: HeadlessMonitorModel?

    /// Image content discovery — manifest cache + probe orchestrator.
    /// Created on auth so it has a username to drive VOSpace I/O;
    /// destroyed on logout because both the cache file and the probe
    /// jobs are user-scoped.
    private(set) var imageDiscoveryCoordinator: ImageDiscoveryCoordinator?
    private(set) var imageDiscoveryModel: ImageDiscoveryModel?

    /// Dashboard widget model for the Canfar Images panel. Owned
    /// alongside the discovery coordinator so logout drops both
    /// together (catalogue + manifests are per-user).
    private(set) var canfarImagesModel: CanfarImagesModel?

    /// Drives presentation of the existing ImageDiscoverySheet
    /// from anywhere in the dashboard. The launch-form magnifier
    /// also writes to this binding so a single sheet instance
    /// serves both surfaces.
    var showImageDiscoverySheet: Bool = false

    /// Pre-selected image id for the sheet — set by the Canfar
    /// Images widget when the user clicks Inspect on a specific
    /// row. The sheet honors this via its existing
    /// `selectedImageID` binding.
    var preselectedDiscoveryImageID: String?

    /// Which tab inside `LaunchFormView` is currently visible.
    /// Lifted out of the view's `@State` so widgets that drive
    /// the form (Canfar Images "use this image" button, agent
    /// tools) can flip the tab to match what they just wrote —
    /// otherwise a click on a headless image would silently
    /// populate the Headless tab while the user is staring at
    /// the Standard tab and concludes nothing happened.
    enum LaunchFormTab: Int, Sendable, Equatable {
        case standard = 0
        case advanced = 1
        case headless = 2
    }
    var launchFormTab: LaunchFormTab = .standard

    /// Routes a `ParsedImage` to the correct launch model and
    /// flips `launchFormTab` to match. Owned here (rather than in
    /// the dashboard) because both launch models live as the
    /// dashboard's properties and aren't visible to e.g. the
    /// Canfar Images widget — but every surface that wants to
    /// "use this image" can call into this single closure.
    var sendImageToLaunchForm: ((ParsedImage) -> Void)?

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
        let authService = AuthService(network: network, endpoints: endpoints)
        self.authService = authService
        self.sessionService = SessionService(network: network, endpoints: endpoints)
        self.imageService = ImageService(network: network, endpoints: endpoints)
        self.platformService = PlatformService(network: network, endpoints: endpoints)
        self.storageService = StorageService(network: network, endpoints: endpoints)
        self.headlessService = HeadlessService(network: network, endpoints: endpoints)

        // Auth lifecycle owns the auth-only state; AppState orchestrates the
        // cross-module reactions (headless monitor, portal-cache prewarm,
        // navigation, sheet routing) via the controller's callbacks.
        let auth = AuthLifecycleController(authService: authService)
        self.auth = auth

        // Route Keychain through the shared addon-family access group so every
        // first-party addon can read the CADC token without re-authing. Default
        // is unset when the entitlement isn't granted — the call is a no-op.
        KeychainStorage.configure(accessGroup: "A4ABW5VD88.codebg.verbinal.family")

        // Subscribe to MetricKit so crash/hang/CPU-exception payloads
        // accumulate in App Store Connect's Diagnostics dashboard.
        // Without `add(_:)` Apple's pipeline never delivers payloads
        // to either the app or its developer dashboards. Idempotent;
        // safe to call once per process lifetime.
        #if canImport(MetricKit)
        MXMetricManager.shared.add(MetricKitSubscriber.shared)
        #endif

        // Restore saved language preference. didSet does NOT fire for this
        // assignment (Swift rule: property observers skipped inside the
        // declaring class's own init), so no spurious "restart required".
        if let stored = UserDefaults.standard.string(forKey: Self.preferredLocaleKey) {
            self.preferredLocaleIdentifier = stored
        }

        // Wire controller callbacks now that `self` is fully initialised.
        auth.onAuthenticated = { [weak self] in
            self?.afterAuthenticated()
        }
        auth.onSessionExpired = { [weak self] in
            self?.showLoginSheet = true
        }

        // Begin watching for network-path changes (Wi-Fi → Ethernet, VPN flip,
        // disconnects). UI binds to this for connectivity hints.
        networkPath.start()

        // Register the MCP tool surface. Order matters: tools must be
        // registered *before* bootstrap, since the listener captures the
        // router's tool table when it starts.
        agentsService.register(tools: makeAgentTools())

        // Wire the navigator closure the auto-apply path uses to drive
        // follow-on navigation. The closure captures `self` weakly —
        // AppState owns the agentsService, so there's no retain cycle,
        // but a weak capture is the right shape for a callback that
        // outlives the registration moment.
        agentsService.navigator = { [weak self] mode in
            guard let self else { return }
            await MainActor.run { self.navigateTo(mode) }
        }

        // Bring up the MCP server only if the user has previously opted in.
        agentsService.bootstrap()

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
    /// Forwards to the controller, which knows how to validate and tear
    /// down the session if needed.
    private func handleNetworkUnauthorized() async -> Bool {
        await auth.handleNetworkUnauthorized()
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

    // Auth state — owned by AuthLifecycleController. AppState forwards for
    // call sites that read `appState.isAuthenticated` etc. directly. New
    // code should prefer reading off `auth.*` to keep the controller's
    // role explicit.
    let auth: AuthLifecycleController

    var isAuthenticated: Bool { auth.isAuthenticated }
    var isLoading: Bool {
        get { auth.isLoading }
        set { auth.isLoading = newValue }
    }
    var username: String { auth.username }
    var statusMessage: String {
        get { auth.statusMessage }
        set { auth.statusMessage = newValue }
    }
    var userInfo: UserInfo? { auth.userInfo }

    // UI state

    /// One-at-a-time sheet presentation. SwiftUI's `.sheet` modifier only shows
    /// one sheet per view hierarchy — using a single item-based sheet with this
    /// enum prevents silent sheet drops when two triggers fire in the same tick
    /// (e.g. token-expiry login prompt while export is open).
    enum ActiveSheet: String, Identifiable {
        case login, about, export, agentProposals
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

    /// Called on app launch — delegates to the controller.
    func initialize() async {
        await auth.validateStoredToken()
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
    private func afterAuthenticated() {
        if let pending = pendingModeAfterLogin {
            navigateTo(pending)
            pendingModeAfterLogin = nil
        }

        let monitor = HeadlessMonitorModel(headlessService: headlessService)
        monitor.onAuthFailure = { [weak self] in
            Task { @MainActor in
                self?.auth.handleTokenExpired()
            }
        }
        headlessMonitor = monitor
        monitor.startMonitoring()

        // Image discovery — manifest cache + probe orchestration.
        // Created lazily here because the coordinator needs a real
        // username for VOSpace IO. Same lifetime as the headless
        // monitor (set up here, torn down on logout).
        let cacheDir = JSONManifestStore.defaultDirectory()
        let store = JSONManifestStore(directory: cacheDir)
        // Types lookup so the coordinator can pick in-target vs
        // inspector strategy per image. Best-effort: a transient
        // catalogue fetch failure means we fall back to in-target,
        // which is the prior single-strategy behaviour.
        let imageSvc = imageService
        let typesLookup: @Sendable (String) async -> [String]? = { id in
            guard let raws = try? await imageSvc.getImages() else { return nil }
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
            vospace: VOSpaceBrowserService(network: network),
            username: username,
            imageTypesLookup: typesLookup,
            registryAuthProvider: authProvider,
            inspectorImageResolver: inspectorResolver
        )
        imageDiscoveryCoordinator = coord
        imageDiscoveryModel = ImageDiscoveryModel(coordinator: coord)
        canfarImagesModel = CanfarImagesModel(
            imageService: imageService,
            coordinator: coord,
            recentLaunchStore: recentLaunchStore,
            portalSettingsService: portalSettingsService,
            username: username
        )

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

    /// Pass-through to the controller for callers that detected a 401
    /// directly (e.g., `HeadlessMonitorModel.onAuthFailure`). The controller
    /// owns the coalescing + reauth attempt; we tear down the headless
    /// monitor here because that's an AppState-owned dependency.
    func handleTokenExpired() {
        guard auth.isAuthenticated else { return }
        headlessMonitor?.stopMonitoring()
        headlessMonitor = nil
        imageDiscoveryCoordinator = nil
        imageDiscoveryModel = nil
        canfarImagesModel = nil
        auth.handleTokenExpired()
    }

    func logout() async {
        headlessMonitor?.stopMonitoring()
        headlessMonitor = nil
        imageDiscoveryCoordinator = nil
        imageDiscoveryModel = nil
        canfarImagesModel = nil

        // Cancel any in-flight prewarm so it cannot repopulate the cache after clear().
        prewarmTask?.cancel()
        prewarmTask = nil

        // Drop user-scoped cached data — settings are per-user and survive logout/login.
        portalImageCacheService.clear()

        // Tear down auth state via the controller (also cancels any
        // in-flight reauth and asks AuthService to clear the token).
        await auth.clear()
        statusMessage = "Logged out"
    }
}
