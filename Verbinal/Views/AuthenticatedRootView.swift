// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Owns all dashboard models and wires them together.
/// Passes them to the platform-appropriate layout.
struct AuthenticatedRootView: View {
    @Environment(AppState.self) private var appState

    @State private var sessionListModel: SessionListModel?
    @State private var sessionLaunchModel: SessionLaunchModel?
    @State private var platformLoadModel: PlatformLoadModel?
    @State private var storageModel: StorageModel?

    var body: some View {
        Group {
            if let slm = sessionListModel,
               let launch = sessionLaunchModel,
               let plm = platformLoadModel,
               let sm = storageModel {
                #if os(macOS)
                DashboardView(
                    sessionListModel: slm,
                    sessionLaunchModel: launch,
                    platformLoadModel: plm,
                    storageModel: sm
                )
                #else
                AdaptiveLayout(
                    sessionListModel: slm,
                    sessionLaunchModel: launch,
                    platformLoadModel: plm,
                    storageModel: sm
                )
                #endif
            } else {
                ProgressView("Loading...")
            }
        }
        .task { await loadData() }
    }

    private func loadData() async {
        let slm = SessionListModel(sessionService: appState.sessionService)
        let launch = SessionLaunchModel(
            sessionService: appState.sessionService,
            imageService: appState.imageService,
            recentLaunchStore: appState.recentLaunchStore
        )
        let plm = PlatformLoadModel(platformService: appState.platformService)
        let sm = StorageModel(storageService: appState.storageService)

        // Wire session counter callbacks
        launch.sessionCounter = { [weak slm] type in
            slm?.sessionCount(forType: type) ?? 0
        }
        launch.totalSessionCounter = { [weak slm] in
            slm?.sessions.count ?? 0
        }
        launch.sessionNamesForType = { [weak slm] type in
            slm?.sessions
                .filter { $0.sessionType.lowercased() == type.lowercased() }
                .map(\.sessionName) ?? []
        }

        // Wire refresh callback to update launch model limits and suggested name
        slm.onSessionsRefreshed = { [weak launch] in
            launch?.updateSessionLimit()
            launch?.refreshSessionNameIfNeeded()
        }

        sessionListModel = slm
        sessionLaunchModel = launch
        platformLoadModel = plm
        storageModel = sm

        // Load all data concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await slm.loadSessions() }
            group.addTask { await launch.loadImagesAndContext() }
            group.addTask { await plm.loadStats() }
            group.addTask { await sm.loadQuota(username: appState.username) }
        }
    }
}
