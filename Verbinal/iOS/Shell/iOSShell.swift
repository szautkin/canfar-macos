// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Verbinal on iPhone and iPad: four places — Portal, FITS, Cube, Compute
/// (plan 47). A tab bar on iPhone, a sidebar on iPad; one selection on
/// `AppState`, so navigation can drive either. The person's Account is the
/// button with their initials.
struct iOSShell: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass

    var sessionListModel: SessionListModel
    var sessionLaunchModel: SessionLaunchModel
    var platformLoadModel: PlatformLoadModel
    var storageModel: StorageModel

    @State private var showAccount = false
    @State private var seen = PortalSeenStore()
    @State private var reminders = ExpiryReminderScheduler()
    /// Compute's runs, read back from /arc; made once the app's network is at hand.
    @State private var computeHistory: ComputeRunHistory?

    private var sessionFacts: [PortalAttention.SessionFacts] {
        sessionListModel.sessions.map(\.attentionFacts)
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                splitView
            } else {
                tabView
            }
        }
        .sheet(isPresented: $showAccount) {
            iOSAccountSheet(reminders: reminders, sessions: sessionFacts)
        }
        // A reminder per running session, moved whenever the sessions change.
        .onChange(of: sessionListModel.sessions) { _, _ in rescheduleReminders() }
        .onAppear {
            guard computeHistory == nil else { return }
            let appState = appState
            computeHistory = ComputeRunHistory(
                files: VOSpaceBrowserService(network: appState.network, endpoints: appState.endpoints),
                username: { [weak appState] in appState?.username ?? "" })
        }
    }

    private func rescheduleReminders() {
        let facts = sessionFacts
        Task { await reminders.reschedule(facts) }
    }

    // MARK: - iPhone

    private var tabView: some View {
        TabView(selection: Bindable(appState).iOSDashboardTab) {
            ForEach(AppState.iOSDashboardTab.allCases) { place in
                NavigationStack {
                    content(for: place)
                        .toolbar { accountItem }
                }
                .tabItem { Label(place.title, systemImage: place.icon) }
                .tag(place)
            }
        }
    }

    // MARK: - iPad

    private var splitView: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(AppState.iOSDashboardTab.allCases) { place in
                    NavigationLink(value: place) {
                        Label(place.title, systemImage: place.icon)
                    }
                }
            }
            .navigationTitle("Verbinal")
            .toolbar { accountItem }
        } detail: {
            NavigationStack {
                content(for: appState.iOSDashboardTab)
            }
        }
    }

    private var sidebarSelection: Binding<AppState.iOSDashboardTab?> {
        Binding(
            get: { appState.iOSDashboardTab },
            set: { if let place = $0 { appState.iOSDashboardTab = place } }
        )
    }

    private var accountItem: some SwiftUI.ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            iOSAccountButton { showAccount = true }
        }
    }

    // MARK: - The places

    @ViewBuilder
    private func content(for place: AppState.iOSDashboardTab) -> some View {
        switch place {
        case .portal:
            iOSPortalView(
                sessions: sessionListModel,
                launchModel: sessionLaunchModel,
                platformLoad: platformLoadModel,
                storage: storageModel,
                seen: seen,
                onRescheduleReminders: rescheduleReminders,
                onOpenCompute: { appState.iOSDashboardTab = .compute })
        case .fits:
            ContentUnavailableView("No Image Open", systemImage: "photo",
                                   description: Text("The FITS images you open to review appear here."))
                .navigationTitle("FITS")
        case .cube:
            ContentUnavailableView("No Cube Open", systemImage: "cube",
                                   description: Text("The data cubes you open to review appear here."))
                .navigationTitle("Cube")
        case .compute:
            if let computeHistory {
                iOSComputeView(model: appState.remoteComputeModel, history: computeHistory)
            } else {
                ProgressView()
            }
        }
    }
}

extension AppState.iOSDashboardTab {
    var title: LocalizedStringKey {
        switch self {
        case .portal: return "Portal"
        case .fits: return "FITS"
        case .cube: return "Cube"
        case .compute: return "Compute"
        }
    }

    var icon: String {
        switch self {
        case .portal: return "rectangle.stack"
        case .fits: return "photo"
        case .cube: return "cube"
        case .compute: return "terminal"
        }
    }
}
