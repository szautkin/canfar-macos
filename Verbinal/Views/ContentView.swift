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
                        Button {
                            appState.currentMode = .landing
                        } label: {
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
                        Button {
                            appState.currentMode = .landing
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
        }
        #endif
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
        } else if appState.isLoading {
            Spacer()
            ProgressView("Authenticating...")
            Spacer()
        } else {
            // Not authenticated — show prompt
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "lock.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Login Required")
                    .font(.title2)
                Text("Sign in to access sessions and data management.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Back") {
                        appState.currentMode = .landing
                    }
                    .buttonStyle(.bordered)
                    Button("Login") {
                        appState.showLoginSheet = true
                        appState.pendingModeAfterLogin = .portal
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Spacer()
            }
        }
    }

}
