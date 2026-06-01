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
                                preselectedImageID: Bindable(appState).preselectedDiscoveryImageID,
                                onUseInLaunchForm: { image in
                                    sendImageToLaunchForm(image)
                                }
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
                    onPick: { [catalogue = cim.allImages] imageID in
                        // Route the picked image by its declared type
                        // (headless -> Headless tab, else Standard with a
                        // full cascade) through the same path the Canfar
                        // Images row button uses. Looking it up in the
                        // catalogue the sheet was opened with fixes the
                        // previous bug where a headless / cross-type pick
                        // was silently dropped (it wasn't in the current
                        // Standard type's pool); capturing the snapshot
                        // also avoids a no-op if the live list reloads
                        // while the sheet is open.
                        if let match = catalogue.first(where: { $0.id == imageID }) {
                            sendImageToLaunchForm(match)
                        }
                    },
                    catalogue: cim.allImages
                )
                .task(id: appState.preselectedDiscoveryImageID) {
                    // Pre-select the row the user clicked Inspect
                    // on. Sheet's "Use this image" button binds to
                    // selectedImageID and updates accordingly.
                    if let pre = appState.preselectedDiscoveryImageID {
                        // Clear any leftover type filter so the preselected
                        // row is guaranteed visible (a stale filter could
                        // otherwise hide it while "Use this image" stays
                        // enabled, targeting an invisible row).
                        idm.typeFilter = nil
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

    /// Routes a `ParsedImage` to whichever launch model fits its
    /// declared types, then flips the visible launch-form tab so
    /// the user sees the change. Lives on the dashboard because
    /// it's the only surface that holds references to both
    /// `sessionLaunchModel` and `headlessLaunchModel`.
    ///
    /// Single-registry assumption: catalogue images implicitly
    /// flip out of advanced-mode in `SessionLaunchModel`. No
    /// custom-registry write happens here.
    private func sendImageToLaunchForm(_ image: ParsedImage) {
        if image.types.contains("headless") {
            // Headless images route ONLY to the headless form. If it's
            // unavailable (nil model), do nothing rather than load a
            // headless image into the Standard form — SessionLaunchModel
            // excludes "headless" from its session types, so that would
            // pair a Standard type with a headless image and build an
            // invalid launch.
            guard let hm = headlessLaunchModel else { return }
            hm.applyImageSelection(image)
            appState.launchFormTab = .headless
        } else {
            sessionLaunchModel.applyImageSelection(image)
            // Standard tab fits all the cascade-driven types; only
            // jump to Advanced if the user is mid-customising it
            // — that's a future signal we don't track today.
            appState.launchFormTab = .standard
        }
    }
}
