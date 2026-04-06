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
    @State private var storageBrowserModel: StorageBrowserModel?

    var body: some View {
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
                storageContent
            case .fitsViewer:
                fitsViewerContent
            }
        }
        .sheet(isPresented: Bindable(appState).showLoginSheet) {
            LoginSheet()
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .task {
            await appState.initialize()
        }
    }

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
        LandingView()
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
            ResearchRootView(researchModel: researchModel)
        }
        #else
        NavigationStack {
            ResearchRootView(researchModel: researchModel)
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

    // MARK: - FITS Viewer

    @ViewBuilder
    private var fitsViewerContent: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            makeModeToolbar(title: "FITS Viewer", showAbout: $showAbout)
            Divider()
            FITSViewerRootView()
        }
        #else
        FITSViewerRootView()
        #endif
    }

    // MARK: - Storage

    @ViewBuilder
    private var storageContent: some View {
        if appState.isAuthenticated {
            #if os(macOS)
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
            #else
            if let model = storageBrowserModel {
                StorageBrowserRootView(model: model)
            }
            #endif
        } else {
            loginRequiredView(for: .storage)
        }
    }

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
                Button("Back") { appState.navigateBack() }
                    .buttonStyle(.bordered)
                Button("Login") {
                    appState.showLoginSheet = true
                    appState.pendingModeAfterLogin = mode
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    private func initStorageModel() {
        guard storageBrowserModel == nil, !appState.username.isEmpty else { return }
        storageBrowserModel = StorageBrowserModel(
            service: VOSpaceBrowserService(network: appState.network),
            username: appState.username
        )
    }
}
