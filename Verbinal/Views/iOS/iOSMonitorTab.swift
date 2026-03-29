// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(iOS)
import SwiftUI

struct iOSMonitorTab: View {
    @Environment(AppState.self) private var appState

    var storageModel: StorageModel
    var platformLoadModel: PlatformLoadModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StorageQuotaView(model: storageModel)

                if let hm = appState.headlessMonitor {
                    HeadlessJobsView(model: hm)
                }

                PlatformLoadView(model: platformLoadModel)
            }
            .padding()
        }
        .navigationTitle("Monitor")
    }
}
#endif
