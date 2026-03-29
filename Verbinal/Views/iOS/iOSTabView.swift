// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(iOS)
import SwiftUI

struct iOSTabView: View {
    @Environment(AppState.self) private var appState

    var sessionListModel: SessionListModel
    var sessionLaunchModel: SessionLaunchModel
    var platformLoadModel: PlatformLoadModel
    var storageModel: StorageModel

    var body: some View {
        TabView {
            NavigationStack {
                iOSSessionsTab(model: sessionListModel)
            }
            .tabItem {
                Label("Sessions", systemImage: "rectangle.stack")
            }

            NavigationStack {
                iOSLaunchTab(
                    launchModel: sessionLaunchModel,
                    recentLaunchStore: appState.recentLaunchStore,
                    onLaunched: {
                        Task { await sessionListModel.loadSessions() }
                    }
                )
            }
            .tabItem {
                Label("Launch", systemImage: "play.circle")
            }

            NavigationStack {
                iOSMonitorTab(
                    storageModel: storageModel,
                    platformLoadModel: platformLoadModel
                )
            }
            .tabItem {
                Label("Monitor", systemImage: "gauge.with.dots.needle.33percent")
            }

            NavigationStack {
                iOSAccountTab()
            }
            .tabItem {
                Label("Account", systemImage: "person.circle")
            }
        }
    }
}
#endif
