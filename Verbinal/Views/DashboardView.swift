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
    var headlessLaunchModel: HeadlessLaunchModel?
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
                        headlessModel: headlessLaunchModel,
                        imageDiscoveryModel: appState.imageDiscoveryModel,
                        onLaunched: {
                            Task { await sessionListModel.loadSessions() }
                            Task { await appState.headlessMonitor?.loadJobs() }
                        }
                    )
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 16) {
                        if let cim = appState.canfarImagesModel {
                            CanfarImagesView(
                                model: cim,
                                showDiscoverySheet: Bindable(appState).showImageDiscoverySheet,
                                preselectedImageID: Bindable(appState).preselectedDiscoveryImageID
                            )
                        }

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
        .sheet(isPresented: Bindable(appState).showImageDiscoverySheet) {
            if let idm = appState.imageDiscoveryModel,
               let cim = appState.canfarImagesModel {
                ImageDiscoverySheet(
                    model: idm,
                    onPick: { imageID in
                        // Sheet's "Use this image" feeds back into
                        // the launch form's selection so the picker
                        // reflects the choice on dismiss.
                        let pool = sessionLaunchModel.images(forType: sessionLaunchModel.selectedType)
                            .values.flatMap { $0 }
                        if let match = pool.first(where: { $0.id == imageID }) {
                            sessionLaunchModel.selectedImage = match
                        }
                    },
                    catalogue: cim.allImages
                )
                .task(id: appState.preselectedDiscoveryImageID) {
                    // Pre-select the row the user clicked Inspect
                    // on. Sheet's "Use this image" button binds to
                    // selectedImageID and updates accordingly.
                    if let pre = appState.preselectedDiscoveryImageID {
                        idm.selectedImageID = pre
                    }
                }
                .onDisappear {
                    appState.preselectedDiscoveryImageID = nil
                    Task { await cim.refreshFromCache() }
                }
            }
        }
    }
}
