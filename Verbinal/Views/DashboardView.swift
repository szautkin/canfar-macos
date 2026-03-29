// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState

    var sessionListModel: SessionListModel
    var sessionLaunchModel: SessionLaunchModel
    var platformLoadModel: PlatformLoadModel
    var storageModel: StorageModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Top row: Sessions + (Storage / Batch Jobs)
                HStack(alignment: .top, spacing: 16) {
                    SessionListView(model: sessionListModel)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        StorageQuotaView(model: storageModel)
                        if let hm = appState.headlessMonitor {
                            HeadlessJobsView(model: hm)
                        }
                    }
                    .frame(minWidth: 220, maxWidth: 280)
                }

                // Bottom row: Launch Form + (Recent + Platform)
                HStack(alignment: .top, spacing: 16) {
                    LaunchFormView(
                        model: sessionLaunchModel,
                        onLaunched: {
                            Task { await sessionListModel.loadSessions() }
                        }
                    )
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 16) {
                        RecentLaunchesView(
                            store: appState.recentLaunchStore,
                            launchModel: sessionLaunchModel,
                            onRelaunched: {
                                Task { await sessionListModel.loadSessions() }
                            }
                        )

                        PlatformLoadView(model: platformLoadModel)
                    }
                    .frame(minWidth: 280, maxWidth: 380)
                }
            }
            .padding(20)
        }
    }
}
