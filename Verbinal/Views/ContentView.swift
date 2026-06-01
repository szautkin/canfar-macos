// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) var appState
    @State var showAbout = false
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
                appState.dispatch(.openFITS(url: url))
            } else {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
            }
        }
    }

    var body: some View {
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
    }

    @ViewBuilder
    private var mainContent: some View {
        Group {
            switch appState.currentMode {
            case .landing:
                if appState.isLoading {
                    Spacer()
                    ProgressView("Checking authentication...")
                    Spacer()
                } else {
                    landingContent
                }
            case .search:
                searchContent
            case .portal:
                portalContent
            case .research:
                researchContent
            case .storage:
                #if os(macOS)
                storageContent
                #else
                macOSOnlyPlaceholder("Storage")
                #endif
            case .fitsViewer:
                #if os(macOS)
                fitsViewerContent
                #else
                macOSOnlyPlaceholder("FITS Viewer")
                #endif
            }
        }
        // Single sheet presenter — SwiftUI's .sheet has a one-at-a-time limitation,
        // so we drive all three (login, about, export) through one enum-based modifier.
        // This prevents silent sheet drops when two triggers fire in the same tick.
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
    private var landingContent: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            makeLandingToolbar(showAbout: $showAbout)
            Divider()
            LandingView()
        }
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
    private var searchContent: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            makeModeToolbar(title: "Search", showAbout: $showAbout)
            Divider()
            SearchRootView(searchModel: searchModel, researchModel: researchModel)
        }
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
    private var researchContent: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            makeModeToolbar(title: "Research", showAbout: $showAbout)
            Divider()
            ResearchRootView(researchModel: researchModel, searchModel: searchModel)
        }
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
    private var fitsViewerContent: some View {
        VStack(spacing: 0) {
            makeModeToolbar(title: "FITS Viewer", showAbout: $showAbout)
            Divider()
            FITSViewerRootView()
                // Empty-state ContentUnavailableView reports its natural
                // content size (~200pt). Without this, the parent HStack's
                // default vAlignment centres the whole VStack vertically,
                // leaving the toolbar floating mid-window. Forcing the
                // body to fill keeps the toolbar pinned to the top.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var storageContent: some View {
        if appState.isAuthenticated {
            VStack(spacing: 0) {
                makeModeToolbar(title: "Storage", showAbout: $showAbout)
                Divider()
                if let model = storageBrowserModel {
                    StorageBrowserRootView(model: model)
                } else {
                    ProgressView("Loading...")
                        .task { initStorageModel() }
                }
            }
        } else {
            loginRequiredView(for: .storage)
        }
    }
    #endif

    // MARK: - Portal

    @ViewBuilder
    private var portalContent: some View {
        if appState.isAuthenticated {
            #if os(macOS)
            VStack(spacing: 0) {
                makePortalToolbar(showAbout: $showAbout)
                Divider()
                AuthenticatedRootView()
            }
            #else
            AuthenticatedRootView()
            #endif
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
                .controlSize(.large)
            }
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
                appState?.dispatch(.openFITS(url: url))
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
