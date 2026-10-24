// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The signed-in dashboard: its models, built and loaded once, and the
/// platform's layout. On iOS the shell is shown signed in or out, and builds
/// the models itself (plan 49).
struct AuthenticatedRootView: View {
    #if os(macOS)
    @Environment(AppState.self) private var appState

    @State private var models: DashboardModels?

    var body: some View {
        Group {
            if let models {
                DashboardView(
                    sessionListModel: models.sessions,
                    sessionLaunchModel: models.launch,
                    headlessLaunchModel: models.headless,
                    platformLoadModel: models.platformLoad,
                    storageModel: models.storage
                )
            } else {
                ProgressView("Loading...")
            }
        }
        .task {
            let built = DashboardModels(appState: appState)
            models = built
            await built.load(username: appState.username)
        }
    }
    #else
    var body: some View {
        iOSShell()
    }
    #endif
}
