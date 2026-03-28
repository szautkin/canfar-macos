// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState

    @State private var sessionListModel: SessionListModel?
    @State private var sessionLaunchModel: SessionLaunchModel?
    @State private var platformLoadModel: PlatformLoadModel?
    @State private var storageModel: StorageModel?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Top row: Sessions + Storage
                HStack(alignment: .top, spacing: 16) {
                    if let slm = sessionListModel {
                        SessionListView(model: slm)
                            .frame(maxWidth: .infinity)
                    }
                    if let sm = storageModel {
                        StorageQuotaView(model: sm)
                            .frame(minWidth: 220, maxWidth: 280)
                    }
                }

                // Bottom row: Launch Form + (Recent + Platform)
                HStack(alignment: .top, spacing: 16) {
                    if let launchModel = sessionLaunchModel {
                        LaunchFormView(
                            model: launchModel,
                            onLaunched: {
                                Task { await sessionListModel?.loadSessions() }
                            }
                        )
                        .frame(maxWidth: .infinity)
                    }

                    VStack(spacing: 16) {
                        RecentLaunchesView(
                            store: appState.recentLaunchStore,
                            launchModel: sessionLaunchModel,
                            onRelaunched: {
                                Task { await sessionListModel?.loadSessions() }
                            }
                        )

                        if let plm = platformLoadModel {
                            PlatformLoadView(model: plm)
                        }
                    }
                    .frame(minWidth: 280, maxWidth: 380)
                }
            }
            .padding(20)
        }
        .task {
            await loadData()
        }
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
