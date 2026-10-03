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

    /// A pick in the image-discovery sheet opens the launch form once that sheet is gone.
    @State private var openLaunchFormAfterDiscovery = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 40)
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: PortalLayout.spacing, verticalSpacing: PortalLayout.spacing) {
                    ForEach(Array(PortalLayout.rows(PortalLayout.arrangement(forWidth: width), present: presentCards).enumerated()),
                            id: \.offset) { _, row in
                        GridRow(alignment: .top) {
                            ForEach(row, id: \.card) { placed in
                                card(placed.card)
                                    // Its columns' width exactly, and its row's height.
                                    .frame(width: PortalLayout.width(ofSpan: placed.cell.span, in: width))
                                    .frame(maxHeight: .infinity, alignment: .top)
                                    .gridCellColumns(placed.cell.span)
                            }
                        }
                    }
                }
                .groupBoxStyle(PortalCardStyle())
                .padding(20)
            }
        }
        .uiPresented("Launch Session", .sheet, isPresented: Bindable(appState).launchFormPresented)
        .sheet(isPresented: Bindable(appState).launchFormPresented) { launchFormSheet }
        .uiPresented("Image Content Discovery", .sheet, isPresented: Bindable(appState).showImageDiscoverySheet)
        .sheet(isPresented: Bindable(appState).showImageDiscoverySheet, onDismiss: {
            if openLaunchFormAfterDiscovery {
                openLaunchFormAfterDiscovery = false
                appState.launchFormPresented = true
            }
        }) {
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
                            sendImageToLaunchForm(match, preferredType: idm.typeFilter, open: false)
                            openLaunchFormAfterDiscovery = true
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
        .task(id: appState.launchFormRequest) {
            guard let request = appState.launchFormRequest else { return }
            appState.launchFormRequest = nil
            apply(request)
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(_ card: PortalCard) -> some View {
        switch card {
        case .platformLoad:
            PlatformLoadView(model: platformLoadModel)
        case .storage:
            StorageQuotaView(model: storageModel)
        case .batchJobs:
            if let hm = appState.headlessMonitor {
                HeadlessJobsView(model: hm)
            } else {
                emptyCell
            }
        case .sessions:
            SessionListView(model: sessionListModel, onLaunch: { appState.launchFormPresented = true })
        case .images:
            if let cim = appState.canfarImagesModel {
                CanfarImagesView(
                    model: cim,
                    showDiscoverySheet: Bindable(appState).showImageDiscoverySheet,
                    preselectedImageID: Bindable(appState).preselectedDiscoveryImageID,
                    onUseInLaunchForm: { image, preferredType in
                        sendImageToLaunchForm(image, preferredType: preferredType, open: true)
                    },
                    registrySearch: appState.registrySearch
                )
            } else {
                emptyCell
            }
        case .recentLaunches:
            RecentLaunchesView(
                store: appState.recentLaunchStore,
                launchModel: sessionLaunchModel,
                onRelaunched: {
                    Task { await sessionListModel.loadSessions() }
                }
            )
        }
    }

    /// The cards that can be shown now: batch jobs and images need what
    /// sign-in sets up.
    private var presentCards: Set<PortalCard> {
        var cards = Set(PortalCard.allCases)
        if appState.headlessMonitor == nil { cards.remove(.batchJobs) }
        if appState.canfarImagesModel == nil { cards.remove(.images) }
        return cards
    }

    /// A card not there yet keeps its place, so the next does not slide into it.
    private var emptyCell: some View {
        Color.clear.frame(height: 0)
    }

    // MARK: - The launch form

    private var launchFormSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Launch Session").font(.title2.bold())
                Spacer()
                Button("Done") { appState.launchFormPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], 20)
            ScrollView {
                LaunchFormView(
                    model: sessionLaunchModel,
                    headlessModel: headlessLaunchModel,
                    imageDiscoveryModel: appState.imageDiscoveryModel,
                    onLaunched: {
                        Task { await sessionListModel.loadSessions() }
                        Task { await appState.headlessMonitor?.loadJobs() }
                        appState.launchFormPresented = false
                    }
                )
                .padding(20)
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 680)
        .environment(appState)
    }

    /// An agent's request: the tab, an image — from the catalogue on the
    /// Standard tab, any other as the Advanced tab's own — then the form.
    private func apply(_ request: AppState.LaunchFormRequest) {
        if let id = request.image {
            if let match = appState.canfarImagesModel?.allImages.first(where: { $0.id == id }) {
                sendImageToLaunchForm(match, preferredType: nil, open: false)
            } else {
                sessionLaunchModel.customImageUrl = id
                appState.launchFormTab = .advanced
            }
        }
        if let tab = request.tab { appState.launchFormTab = tab }
        appState.launchFormPresented = true
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
    private func sendImageToLaunchForm(_ image: ParsedImage, preferredType: String?, open: Bool) {
        // Honor the type the user was filtering by. Catalogue images are often
        // multi-type (e.g. notebook+headless), so routing purely on
        // `types.contains("headless")` would yank a notebook the user picked
        // under the Notebook filter over to the Headless tab. When a specific
        // type was selected, that decides the tab; only with no type context
        // (Default/Popular) do we fall back to the image's own types — and even
        // then only a headless-ONLY image goes to the Headless tab.
        let routeHeadless: Bool
        if let preferredType {
            routeHeadless = (preferredType.lowercased() == "headless")
        } else {
            let types = image.types.map { $0.lowercased() }
            routeHeadless = types.contains("headless") && !types.contains { $0 != "headless" }
        }

        if routeHeadless {
            // Headless routes ONLY to the headless form. If it's unavailable
            // (nil model), do nothing rather than load a headless image into the
            // Standard form — SessionLaunchModel excludes "headless" from its
            // session types, so that would build an invalid launch.
            guard let hm = headlessLaunchModel else { return }
            hm.applyImageSelection(image)
            appState.launchFormTab = .headless
        } else {
            // Standard tab fits all cascade-driven types; pass the user's chosen
            // type so a multi-type image lands on the type they selected.
            sessionLaunchModel.applyImageSelection(image, preferredType: preferredType)
            appState.launchFormTab = .standard
        }
        // So the person sees what changed.
        if open { appState.launchFormPresented = true }
    }
}
