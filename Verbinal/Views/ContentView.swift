// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    /// Read once here — the only place that can — and mirrored into
    /// `AppState.reduceMotion` so the navigation methods (which can fire
    /// from non-view contexts) honour the guard. Also selects the
    /// mode-switch and Terms-gate transitions below.
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var showAbout = false
    /// First-launch Terms-of-Use acceptance gate; blocks the app until accepted.
    @State private var legal = LegalAgreementService()
    #if os(macOS)
    /// One-shot first-run Welcome card (B2). Mirrors the legal one-shot
    /// (`LegalAgreementService.acceptedVersion`): the stored value is the
    /// Welcome version last seen; the card shows once when it trails
    /// `WelcomePreferences.currentVersion`, and we stamp it on dismiss.
    /// Shown only AFTER the Terms gate dismisses — it never alters the
    /// gate's blocking contract, it just appears once the gate is gone.
    @AppStorage(WelcomePreferences.seenVersionKey) private var welcomeSeenVersion = 0
    #endif
    @State private var searchModel = SearchFormModel()
    @State private var researchModel = ResearchModel()
    #if os(macOS)
    // StorageBrowserModel, FileBrowserModel, and FileBrowserPanel live in
    // feature dirs excluded from the iOS target. The shell that hosts the
    // browser column is macOS-only — iOS routes Storage to a placeholder.
    @State private var storageBrowserModel: StorageBrowserModel?
    @State private var fileBrowserModel = FileBrowserModel()
    @State var showFileBrowser = false
    #endif

    private func initResearchModel() {
        researchModel.onOpenFile = { [weak appState] url in
            guard let appState else { return }
            let ext = url.pathExtension.lowercased()
            if FileHelper.isFITS(ext) {
                appState.openAstronomyFITS(url: url)
            } else {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
            }
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                #if os(macOS)
                if showFileBrowser {
                    FileBrowserPanel(model: fileBrowserModel) { url in
                        handleFileOpen(url)
                    }
                    .frame(width: 260)
                    Divider()
                }
                #endif

                mainContent
            }

            // Block all app interaction behind the Terms gate until accepted.
            // The EXIT fades (the gate's accept buttons flip `hasAcceptedCurrent`
            // inside `withAppAnimation`, driving this `.transition`); the
            // APPEARANCE stays instant — at launch the gate is the initial
            // render with no enclosing transaction, so it blocks immediately.
            // Under Reduce Motion `.appFade` is still a plain cross-fade and the
            // animated flip is nil'd, so the exit is instant too.
            if !legal.hasAcceptedCurrent {
                LegalAgreementGate(service: legal)
                    .transition(.appFade)
                    .zIndex(1)
            }
        }
        // App-wide presenters live on the root ZStack — NOT on the transitioning
        // `modeBody` — so the single sheet host stays mounted across mode
        // cross-fades and never re-presents mid-transition. (Previously these
        // sat on `mainContent`; with the chrome hoist the body now transitions,
        // so the presenters must hang above it on a stable parent.)
        // Single sheet presenter — SwiftUI's .sheet has a one-at-a-time limitation,
        // so we drive all (login, about, export, agentProposals) through one
        // enum-based modifier. This prevents silent sheet drops when two triggers
        // fire in the same tick.
        .sheet(item: Bindable(appState).activeSheet) { sheet in
            switch sheet {
            case .login:
                LoginSheet()
            case .about:
                AboutSheet()
            case .export:
                #if os(macOS)
                globalExportDialog
                #else
                EmptyView()
                #endif
            case .agentProposals:
                #if os(macOS)
                ProposalStripSheet()
                    .environment(appState)
                #else
                EmptyView()
                #endif
            case .features:
                #if os(macOS)
                FeaturesSheet()
                    .environment(appState)
                #else
                EmptyView()
                #endif
            case .welcome:
                #if os(macOS)
                WelcomeSheet()
                    .environment(appState)
                #else
                EmptyView()
                #endif
            case .mcpSetupWizard:
                #if os(macOS)
                MCPSetupWizard()
                    .environment(appState)
                #else
                EmptyView()
                #endif
            }
        }
        .task {
            initResearchModel()
            await appState.initialize()
        }
        .task(id: appState.pendingSearchCoordinate) {
            guard let coord = appState.pendingSearchCoordinate else { return }
            appState.pendingSearchCoordinate = nil
            searchModel.setSearchCoordinates(ra: coord.ra, dec: coord.dec)
        }
        // Bridge local `showAbout` binding (used by toolbars) to the unified
        // activeSheet on AppState. When toolbars set `showAbout = true`, we
        // route it to `activeSheet = .about` and reset the local flag.
        .onChange(of: showAbout) { _, newValue in
            if newValue {
                appState.activeSheet = .about
                showAbout = false
            }
        }
        // Mirror the environment Reduce-Motion flag into AppState so the
        // navigation methods can consult it from non-view contexts.
        .onAppear { appState.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, newValue in
            appState.reduceMotion = newValue
        }
        #if os(macOS)
        // B2 — first-run Welcome card. Present once the Terms gate has been
        // accepted (so it never competes with or weakens the blocking gate)
        // and the current Welcome version hasn't been seen. Fired both at
        // launch (returning users who already accepted Terms) and on the
        // accept transition (true first launch), guarded by `maybeShowWelcome`.
        .onAppear { maybeShowWelcome() }
        .onChange(of: legal.hasAcceptedCurrent) { _, accepted in
            if accepted { maybeShowWelcome() }
        }
        #endif
    }

    #if os(macOS)
    /// Present the first-run Welcome card iff Terms are accepted, the card
    /// hasn't been seen for the current version, and no other sheet is up
    /// (the single-sheet host can show only one — don't stomp login/export).
    private func maybeShowWelcome() {
        guard legal.hasAcceptedCurrent,
              welcomeSeenVersion < WelcomePreferences.currentVersion,
              appState.activeSheet == nil
        else { return }
        appState.activeSheet = .welcome
    }
    #endif

    @ViewBuilder
    private var mainContent: some View {
        #if os(macOS)
        // CHROME HOIST (macOS): the mode toolbar + Divider live OUT here so the
        // window chrome PERSISTS across the mode cross-fade — only `modeBody`
        // transitions. Previously each per-mode `VStack { toolbar; Divider; body }`
        // re-mounted the whole title bar on every switch, flashing the chrome
        // through the fade and undercutting it. The toolbar now stays put and
        // its title cross-fades in place (`hoistedModeToolbar`).
        //
        // Exception: while the auth check runs on the landing mode there is no
        // chrome yet — show the bare spinner so the toolbar doesn't appear over
        // a "Checking authentication…" state.
        if appState.currentMode == .landing && appState.isLoading {
            // Auth check on landing has no chrome yet — bare spinner.
            VStack {
                Spacer()
                ProgressView("Checking authentication...")
                Spacer()
            }
        } else if showsModeChrome {
            VStack(spacing: 0) {
                hoistedModeToolbar
                Divider()
                modeBody
            }
        } else {
            // Portal / Storage while signed out render a standalone
            // login-required screen with NO mode toolbar (matches the
            // pre-hoist behaviour, which never wrapped that screen in chrome).
            modeBody
        }
        #else
        modeBody
        #endif
    }

    #if os(macOS)
    /// Whether the persistent mode chrome (toolbar + Divider) should be shown.
    /// Hidden for the signed-out Portal / Storage login-required screen, which
    /// is a standalone prompt with its own buttons — wrapping it in a back-arrow
    /// mode toolbar would be redundant and was never done before the hoist.
    private var showsModeChrome: Bool {
        switch appState.currentMode {
        case .portal, .storage:
            return appState.isAuthenticated
        default:
            return true
        }
    }

    /// The persistent macOS mode toolbar, chosen by `currentMode`. It lives
    /// above the transitioning `modeBody` so it does NOT fade with the body;
    /// only the title text cross-fades in place (each `make…Toolbar` renders a
    /// title `Text`, and switching the toolbar variant animates under the
    /// enclosing `withAppAnimation(AppMotion.screen)` transaction). Landing and
    /// Portal keep their distinct toolbars (account menu, file-browser button);
    /// the rest share the generic back-arrow mode toolbar.
    @ViewBuilder
    private var hoistedModeToolbar: some View {
        switch appState.currentMode {
        case .landing:
            makeLandingToolbar(showAbout: $showAbout)
        case .portal:
            makePortalToolbar(showAbout: $showAbout)
        case .search:
            makeModeToolbar(title: "Search", showAbout: $showAbout)
        case .research:
            makeModeToolbar(title: "Research", showAbout: $showAbout)
        case .storage:
            makeModeToolbar(title: "Storage", showAbout: $showAbout)
        case .fitsViewer:
            makeModeToolbar(title: "FITS Viewer", showAbout: $showAbout)
        case .cubeViewer:
            makeModeToolbar(title: "Cube Viewer", showAbout: $showAbout)
        case .aiGuide:
            makeModeToolbar(title: "AI Guide", showAbout: $showAbout)
        }
    }
    #endif

    /// The transitioning body — everything BELOW the persistent macOS chrome.
    /// On iOS this is the whole screen (no hoisted toolbar). The mode-switch
    /// transition lives here, keyed on the mode VALUE (never `.id`, which would
    /// rebuild the subtree and re-fire `.task`/`loadData`, landing the fade on a
    /// spinner). The transaction is supplied by `withAppAnimation(AppMotion.screen)`
    /// inside `navigateTo`/`navigateBack`. Under Reduce Motion the call-site
    /// animation is nil'd and we fall back to pure opacity (no scale "breathing",
    /// no slide) for vestibular safety.
    @ViewBuilder
    private var modeBody: some View {
        Group {
            switch appState.currentMode {
            case .landing:
                landingBody
            case .search:
                searchBody
            case .portal:
                portalBody
            case .research:
                researchBody
            case .storage:
                #if os(macOS)
                storageBody
                #else
                macOSOnlyPlaceholder("Storage")
                #endif
            case .fitsViewer:
                #if os(macOS)
                fitsViewerBody
                #else
                macOSOnlyPlaceholder("FITS Viewer")
                #endif
            case .cubeViewer:
                #if os(macOS)
                cubeViewerBody
                #else
                macOSOnlyPlaceholder("Cube Viewer")
                #endif
            case .aiGuide:
                #if os(macOS)
                aiGuideBody
                #else
                macOSOnlyPlaceholder("AI Guide")
                #endif
            }
        }
        .transition(modeTransition)
    }

    /// macOS = subtle cross-fade (± ≤1.5% scale); iOS = directional slide keyed
    /// on `appState.navDirection`. Reduce Motion collapses both to pure opacity.
    private var modeTransition: AnyTransition {
        if reduceMotion { return .appFade }
        #if os(macOS)
        return .appScreen
        #else
        return .appScreenDirectional(forward: appState.navDirection == .forward)
        #endif
    }

    #if os(macOS)
    /// Global export dialog — can be opened via ⌘⇧E from anywhere in the app.
    /// Exposes whichever modules are currently populated.
    private var globalExportDialog: some View {
        ExportDialogView(
            availableModules: buildGlobalExportModules(),
            exportService: researchModel.exportService,
            onVOSpaceUpload: { bundleURL in
                let vospace = VOSpaceBrowserService(network: appState.network)
                return try await researchModel.exportService.uploadBundleToVOSpace(
                    bundleURL: bundleURL,
                    vospace: vospace,
                    username: appState.username
                )
            },
            canUploadToVOSpace: appState.isAuthenticated && !appState.username.isEmpty,
            onComplete: { url in
                let summary = ResearchExporter.itemCountLabel(
                    observations: researchModel.observationStore.observations.count,
                    notes: researchModel.noteStore.notes.count
                )
                NotificationService.sendExportCompleted(
                    bundleName: url.lastPathComponent,
                    moduleSummary: summary
                )
            }
        )
    }

    private func buildGlobalExportModules() -> [ExportDialogView.ModuleSelection] {
        var modules: [ExportDialogView.ModuleSelection] = []

        modules.append(
            ExportDialogView.ModuleSelection(
                moduleID: "research",
                displayName: "Research",
                itemCountLabel: ResearchExporter.itemCountLabel(
                    observations: researchModel.observationStore.observations.count,
                    notes: researchModel.noteStore.notes.count
                ),
                module: ResearchExporter(
                    observationStore: researchModel.observationStore,
                    noteStore: researchModel.noteStore
                ),
                isEnabled: true
            )
        )

        let saved = searchModel.savedQueryStore.queries.count
        let recent = searchModel.recentSearchStore.searches.count
        let searchLabel: String
        if saved == 0 && recent == 0 {
            searchLabel = "empty"
        } else {
            searchLabel = "\(saved) saved, \(recent) recent"
        }
        modules.append(
            ExportDialogView.ModuleSelection(
                moduleID: "search",
                displayName: "Search",
                itemCountLabel: searchLabel,
                module: SearchExporter(
                    savedQueryStore: searchModel.savedQueryStore,
                    recentSearchStore: searchModel.recentSearchStore
                ),
                isEnabled: false
            )
        )

        return modules
    }
    #endif

    // MARK: - Landing

    @ViewBuilder
    private var landingBody: some View {
        #if os(macOS)
        LandingView()
        #else
        // iOS doesn't use the mode-card Mac landing. The app's home is the
        // tab bar (iPhone) / split view (iPad), so once authenticated we
        // jump straight to AuthenticatedRootView, which already chooses
        // AdaptiveLayout on iOS. Signed-out users get the same
        // login-required prompt the other modes use.
        if appState.isAuthenticated {
            AuthenticatedRootView()
        } else {
            loginRequiredView(for: .landing)
        }
        #endif
    }

    // MARK: - Search

    @ViewBuilder
    private var searchBody: some View {
        #if os(macOS)
        SearchRootView(searchModel: searchModel, researchModel: researchModel)
        #else
        NavigationStack {
            SearchRootView(searchModel: searchModel, researchModel: researchModel)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { appState.navigateBack() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
        }
        #endif
    }

    // MARK: - Research

    @ViewBuilder
    private var researchBody: some View {
        #if os(macOS)
        ResearchRootView(researchModel: researchModel, searchModel: searchModel)
        #else
        NavigationStack {
            ResearchRootView(researchModel: researchModel, searchModel: searchModel)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { appState.navigateBack() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
        }
        #endif
    }

    // MARK: - FITS Viewer & Storage (macOS-only — types live in excluded dirs)

    #if os(macOS)
    @ViewBuilder
    private var fitsViewerBody: some View {
        FITSViewerRootView()
            // Empty-state ContentUnavailableView reports its natural content
            // size (~200pt). Without this the body wouldn't fill the area below
            // the persistent toolbar, leaving the divider floating mid-window.
            // Forcing the body to fill keeps it pinned just under the chrome.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Cube Viewer — a sibling of the FITS viewer (its own mode/tile), not nested
    /// inside it. Reuses VerbinalKit rendering but is a fully separate module.
    @ViewBuilder
    private var cubeViewerBody: some View {
        CubeViewerRootView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var aiGuideBody: some View {
        AIGuideView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var storageBody: some View {
        if appState.isAuthenticated {
            if let model = storageBrowserModel {
                StorageBrowserRootView(model: model)
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { initStorageModel() }
            }
        } else {
            loginRequiredView(for: .storage)
        }
    }
    #endif

    // MARK: - Portal

    @ViewBuilder
    private var portalBody: some View {
        if appState.isAuthenticated {
            AuthenticatedRootView()
        } else {
            loginRequiredView(for: .portal)
        }
    }

    // MARK: - Login Required (shared)

    private func loginRequiredView(for mode: AppMode) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Login Required")
                .font(.title2)
            Text("Sign in to continue.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                #if os(iOS)
                // iOS landing is a dead-end when signed out — there's no
                // previous screen to go back to. Repurpose the leading
                // button as a soft-close instead.
                Button("Close") { AppLifecycle.suspend() }
                    .buttonStyle(.bordered)
                #else
                Button("Back") { appState.navigateBack() }
                    .buttonStyle(.bordered)
                #endif
                Button("Login") {
                    appState.showLoginSheet = true
                    appState.pendingModeAfterLogin = mode
                }
                .buttonStyle(.borderedProminent)
            }
            // Size the row to its buttons and keep each label on one line —
            // otherwise a width-constrained container squishes the prominent
            // button toward square, wrapping "Login" to "Lo-gin" and rendering
            // the automatic capsule as a circle.
            .controlSize(.large)
            .lineLimit(1)
            .fixedSize()
            Spacer()
            #if os(iOS)
            Button("About Verbinal") { appState.activeSheet = .about }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
            #endif
        }
    }

    // MARK: - iOS Placeholder

    #if os(iOS)
    private func macOSOnlyPlaceholder(_ feature: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("\(feature) is available on macOS")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Go Back") { appState.navigateBack() }
                .buttonStyle(.bordered)
            Spacer()
        }
    }
    #endif

    // MARK: - Helpers

    #if os(macOS)
    private func initStorageModel() {
        guard storageBrowserModel == nil, !appState.username.isEmpty else { return }
        let model = StorageBrowserModel(
            service: VOSpaceBrowserService(network: appState.network),
            username: appState.username
        )
        model.onOpenFile = { [weak appState] url in
            let ext = url.pathExtension.lowercased()
            if FileHelper.isFITS(ext) {
                appState?.openAstronomyFITS(url: url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        storageBrowserModel = model
    }

    private func handleFileOpen(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if FileHelper.isFITS(ext) {
            appState.dispatch(.openFITS(url: url))
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    #endif
}
