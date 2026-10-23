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
    /// The files opened lately on this device.
    @State private var recents = iOSRecentFiles()
    /// The file open in FITS, and in Cube (plan 47 phase 3: header first).
    @State private var openedFITS: FileInspection?
    @State private var openedCube: FileInspection?
    /// Which place's Open sheet is up.
    @State private var openingFor: AppState.iOSDashboardTab?
    /// FITS shows its viewer (an image is open), not the file's page.
    @State private var fitsViewerShown = false

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
        .sheet(item: $openingFor) { place in
            iOSOpenSheet(recents: recents) { file in open(file, in: place) }
        }
        // A file another app sent ("Open in Verbinal"): it opens in FITS.
        .onChange(of: appState.pendingFITSURL, initial: true) { _, url in
            guard let url else { return }
            appState.pendingFITSURL = nil
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let file = FileRef.device(url) else { return }
            recents.add(file)
            open(file, in: .fits)
        }
        .environment(\.iOSOpenFile, { file in
            recents.add(file)
            open(file, in: .fits)
        })
        .environment(\.iOSViewImage, { url in viewImage(url) })
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

    /// Opens `file` in a place, header first, and shows that place.
    private func open(_ file: FileRef, in place: AppState.iOSDashboardTab) {
        let inspection = FileInspection(
            file: file, storage: VOSpaceBrowserService(network: appState.network, endpoints: appState.endpoints),
            username: appState.username)
        if place == .cube { openedCube = inspection } else { openedFITS = inspection }
        appState.iOSDashboardTab = place == .cube ? .cube : .fits
        // On this device already: straight to the image; from storage, its page first.
        if place == .fits, let local = inspection.local.value {
            viewImage(local)
        } else if place == .fits {
            fitsViewerShown = false
        }
    }

    /// Shows a local FITS file in the viewer: its own tab, or the one it has.
    private func viewImage(_ url: URL) {
        let host = appState.fitsTabHost
        appState.iOSDashboardTab = .fits
        fitsViewerShown = true
        if let index = host.tabs.firstIndex(where: { $0.fileURL == url }) {
            host.activeTabIndex = index
        } else {
            Task { _ = await host.openNewTab(url: url) }
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
            if fitsViewerShown, !appState.fitsTabHost.tabs.isEmpty {
                iOSFITSViewer(host: appState.fitsTabHost,
                              onOpen: { openingFor = .fits },
                              onShowFile: { fitsViewerShown = false })
            } else {
                opened(openedFITS, place: .fits, empty: "No Image Open", icon: "photo",
                       description: "The FITS images you open to review appear here.")
            }
        case .cube:
            opened(openedCube, place: .cube, empty: "No Cube Open", icon: "cube",
                   description: "The data cubes you open to review appear here.")
        case .compute:
            if let computeHistory {
                iOSComputeView(model: appState.remoteComputeModel, history: computeHistory)
            } else {
                ProgressView()
            }
        }
    }
}

extension iOSShell {
    /// A place's opened file, header first, or how to open one.
    @ViewBuilder
    func opened(_ inspection: FileInspection?, place: AppState.iOSDashboardTab, empty: LocalizedStringKey,
                icon: String, description: LocalizedStringKey) -> some View {
        Group {
            if let inspection {
                iOSFileView(inspection: inspection)
                    .id(inspection.id)
            } else {
                ContentUnavailableView {
                    Label(empty, systemImage: icon)
                } description: {
                    Text(description)
                } actions: {
                    Button("Open…") { openingFor = place }
                        .buttonStyle(.borderedProminent)
                }
                .navigationTitle(place.title)
            }
        }
        .toolbar {
            if inspection != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openingFor = place } label: { Label("Open…", systemImage: "folder") }
                }
            }
        }
    }
}

/// Opens a file in FITS from anywhere below the shell — a Compute run's output.
private struct iOSOpenFileKey: EnvironmentKey {
    static let defaultValue: @MainActor (FileRef) -> Void = { _ in }
}

/// Shows a local FITS file in the viewer, from a file's page.
private struct iOSViewImageKey: EnvironmentKey {
    static let defaultValue: @MainActor (URL) -> Void = { _ in }
}

extension EnvironmentValues {
    var iOSOpenFile: @MainActor (FileRef) -> Void {
        get { self[iOSOpenFileKey.self] }
        set { self[iOSOpenFileKey.self] = newValue }
    }

    var iOSViewImage: @MainActor (URL) -> Void {
        get { self[iOSViewImageKey.self] }
        set { self[iOSViewImageKey.self] = newValue }
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
