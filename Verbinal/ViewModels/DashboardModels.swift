// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The Portal's models, wired together: built when the person is signed in,
/// by the Mac's dashboard and the iOS shell alike (plan 49), and dropped
/// with the sign-in.
@MainActor
struct DashboardModels {
    let sessions: SessionListModel
    let launch: SessionLaunchModel
    let headless: HeadlessLaunchModel
    let platformLoad: PlatformLoadModel
    let storage: StorageModel

    init(appState: AppState) {
        let sessions = SessionListModel(sessionService: appState.sessionService)
        let launch = SessionLaunchModel(
            sessionService: appState.sessionService,
            imageService: appState.imageService,
            recentLaunchStore: appState.recentLaunchStore,
            cacheService: appState.portalImageCacheService,
            settingsService: appState.portalSettingsService,
            userImages: appState.userImages,
            username: appState.username
        )
        // The sizes it offers, for show_launch_form to check (plan 30 T5).
        appState.sessionLaunchModelForTools = launch

        // Wire session counter callbacks
        launch.sessionCounter = { [weak sessions] type in
            sessions?.sessionCount(forType: type) ?? 0
        }
        launch.totalSessionCounter = { [weak sessions] in
            sessions?.sessions.count ?? 0
        }
        launch.sessionNamesForType = { [weak sessions] type in
            sessions?.sessions
                .filter { $0.sessionType.lowercased() == type.lowercased() }
                .map(\.sessionName) ?? []
        }

        // Wire refresh callback to update launch model limits and suggested name
        sessions.onSessionsRefreshed = { [weak launch] in
            launch?.updateSessionLimit()
            launch?.refreshSessionNameIfNeeded()
        }

        self.sessions = sessions
        self.launch = launch
        // The headless launch model only needs HeadlessService +
        // RecentLaunchStore; the image catalogue is borrowed read-only
        // from `launch` at render time, so no separate fetch.
        headless = HeadlessLaunchModel(
            headlessService: appState.headlessService,
            recentLaunchStore: appState.recentLaunchStore
        )
        platformLoad = PlatformLoadModel(platformService: appState.platformService)
        storage = StorageModel(storageService: appState.storageService)
    }

    /// Loads all of them at once.
    func load(username: String) async {
        let sessions = sessions, launch = launch, platformLoad = platformLoad, storage = storage
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sessions.loadSessions() }
            group.addTask { await launch.loadImagesAndContext() }
            group.addTask { await platformLoad.loadStats() }
            group.addTask { await storage.loadQuota(username: username) }
        }
    }
}
