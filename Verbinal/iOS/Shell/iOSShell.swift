// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Verbinal on iPhone and iPad: four places — Portal, FITS, Cube, Compute
/// (plan 47). A tab bar on iPhone, a sidebar on iPad; one selection on
/// `AppState`, so navigation can drive either. Everything else is in the
/// menu, behind the button with the person's initials (plan 48).
struct iOSShell: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass

    var sessionListModel: SessionListModel
    var sessionLaunchModel: SessionLaunchModel
    var platformLoadModel: PlatformLoadModel
    var storageModel: StorageModel

    @State private var showMenu = false
    /// The files Verbinal holds on this device (plan 48).
    @State private var library = DeviceLibrary()
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
    /// Cube shows its viewer (a cube is open), not the file's page.
    @State private var cubeViewerShown = false

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
        .sheet(isPresented: $showMenu) {
            iOSMenuSheet(reminders: reminders, sessions: sessionFacts, library: library, storage: storageModel,
                         onOpen: { file in
                             showMenu = false
                             recents.add(file)
                             open(file, in: .fits)
                         },
                         onClose: closeFiles)
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
        .environment(\.iOSViewCube, { url in viewCube(url) })
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
            username: appState.username, files: library.store)
        if place == .cube { openedCube = inspection } else { openedFITS = inspection }
        appState.iOSDashboardTab = place == .cube ? .cube : .fits
        // On this device already: straight to the image or the cube, whichever
        // it is; from storage, its page first.
        if let local = inspection.local.value {
            Task {
                if await AppState.fitsIsCube(local) {
                    openedCube = inspection
                    viewCube(local)
                } else {
                    openedFITS = inspection
                    viewImage(local)
                }
            }
        } else if place == .cube {
            cubeViewerShown = false
        } else {
            fitsViewerShown = false
        }
    }

    /// Shows a local cube in the cube viewer: the tab that has it, the empty
    /// first tab, or a new one.
    private func viewCube(_ url: URL) {
        let host = appState.cubeTabHost
        appState.iOSDashboardTab = .cube
        cubeViewerShown = true
        if let index = host.tabs.firstIndex(where: { $0.fileURL == url }) {
            host.activeTabIndex = index
        } else if let index = host.tabs.firstIndex(where: { !$0.hasData && !$0.document.state.isOpening }) {
            host.activeTabIndex = index
            Task { await host.tabs[index].open(url: url) }
        } else {
            Task { _ = await host.openNewTab(url: url) }
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
                        .toolbar { menuItem }
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
            .toolbar { menuItem }
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

    private var menuItem: some SwiftUI.ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            iOSMenuButton { showMenu = true }
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
                              onShowFile: { fitsViewerShown = false },
                              onClosedAll: {
                                  fitsViewerShown = false
                                  openedFITS = nil
                              })
            } else {
                opened(openedFITS, place: .fits, empty: "No Image Open", icon: "photo",
                       description: "The FITS images you open to review appear here.")
            }
        case .cube:
            if cubeViewerShown, appState.cubeTabHost.tabs.contains(where: { $0.hasData || $0.document.state.isOpening }) {
                iOSCubeViewer(host: appState.cubeTabHost,
                              onOpen: { openingFor = .cube },
                              onShowFile: { cubeViewerShown = false },
                              onClosedAll: {
                                  cubeViewerShown = false
                                  openedCube = nil
                              })
            } else {
                opened(openedCube, place: .cube, empty: "No Cube Open", icon: "cube",
                       description: "The data cubes you open to review appear here.")
            }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { closePage(place) } label: { Label("Close", systemImage: "xmark") }
                }
            }
        }
    }
}

extension iOSShell {
    /// Closes a file's page; an image or cube it shows stays open in its viewer.
    func closePage(_ place: AppState.iOSDashboardTab) {
        if place == .cube { openedCube = nil } else { openedFITS = nil }
    }

    /// Before files on this device go (plan 48): the viewer tabs showing
    /// them close, and a page that had one forgets it — a storage file's
    /// page stays, since storage still has it.
    func closeFiles(_ urls: [URL]) {
        let gone = Set(urls.map { $0.resolvingSymlinksInPath().path })
        let isGone: (URL?) -> Bool = { url in url.map { gone.contains($0.resolvingSymlinksInPath().path) } ?? false }

        let fits = appState.fitsTabHost
        for index in fits.tabs.indices.reversed() where isGone(fits.tabs[index].fileURL) {
            fits.closeTab(at: index)
        }
        if fits.tabs.isEmpty { fitsViewerShown = false }

        let cubes = appState.cubeTabHost
        for index in cubes.tabs.indices.reversed() where isGone(cubes.tabs[index].fileURL) {
            if cubes.tabs.count > 1 {
                cubes.closeTab(at: index)
            } else {
                cubes.tabs = [CubeViewerModel()]
                cubes.activeTabIndex = 0
                cubeViewerShown = false
            }
        }

        for (inspection, place) in [(openedFITS, AppState.iOSDashboardTab.fits), (openedCube, .cube)] {
            guard let inspection, isGone(inspection.local.value) else { continue }
            if inspection.file.isRemote { inspection.forgetLocal() } else { closePage(place) }
        }

        // A device file that goes leaves Recent too; a storage file stays there.
        for file in recents.items where isGone(file.deviceURL()) {
            recents.remove(file)
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

/// Shows a local cube in the cube viewer, from a file's page.
private struct iOSViewCubeKey: EnvironmentKey {
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

    var iOSViewCube: @MainActor (URL) -> Void {
        get { self[iOSViewCubeKey.self] }
        set { self[iOSViewCubeKey.self] = newValue }
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
