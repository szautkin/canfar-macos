// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(iOS)
import SwiftUI

/// Selects between the desktop-style DashboardView (iPad landscape)
/// and the TabView-based layout (iPhone / iPad portrait).
struct AdaptiveLayout: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppState.self) private var appState

    var sessionListModel: SessionListModel
    var sessionLaunchModel: SessionLaunchModel
    var platformLoadModel: PlatformLoadModel
    var storageModel: StorageModel

    var body: some View {
        if sizeClass == .regular {
            DashboardView(
                sessionListModel: sessionListModel,
                sessionLaunchModel: sessionLaunchModel,
                platformLoadModel: platformLoadModel,
                storageModel: storageModel
            )
        } else {
            iOSTabView(
                sessionListModel: sessionListModel,
                sessionLaunchModel: sessionLaunchModel,
                platformLoadModel: platformLoadModel,
                storageModel: storageModel
            )
        }
    }
}
#endif
