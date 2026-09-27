// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Appliers for every proposal-gated write tool: what runs when a pending
/// proposal is applied (by the user, or at once under auto-apply).
extension AppState {
    /// Build and register the appliers that the proposal strip dispatches
    /// to. Stores are passed in so the same instance the read tools see
    /// is what the appliers mutate.
    func registerWriteAppliers(savedQueryStore: SavedQueryStore,
                                       noteStore: ObservationNoteStore,
                                       observationStore: ObservationStore,
                                       vospace: VOSpaceBrowserService) {
        let downloader = DownloadService(endpoints: endpoints)
        let activity = agentsService.activityStore
        let recentLaunchStore = RecentLaunchStore()
        var appliers: [any ProposalApplier] = [
            SaveQueryApplier(store: savedQueryStore, activity: activity),
            UpdateSavedQueryApplier(store: savedQueryStore, activity: activity),
            DeleteSavedQueryApplier(store: savedQueryStore, activity: activity),
            UpdateObservationNoteApplier(store: noteStore, activity: activity),
            BulkUpdateObservationNotesApplier(store: noteStore, activity: activity),
            DownloadObservationApplier(downloadService: downloader,
                                       observationStore: observationStore,
                                       activity: activity),
            DownloadObservationsBulkApplier(downloadService: downloader,
                                            observationStore: observationStore,
                                            activity: activity),
            DeleteDownloadedObservationApplier(store: observationStore,
                                               downloadService: downloader,
                                               activity: activity),
            WorkflowApplier(kind: "save_workflow", store: workflowStore, activity: activity),
            WorkflowApplier(kind: "update_workflow", store: workflowStore, activity: activity),
            WorkflowApplier(kind: "set_workflow_step", store: workflowStore, activity: activity),
            WorkflowApplier(kind: "use_workflow", store: workflowStore, activity: activity),
            WorkflowApplier(kind: "delete_workflow", store: workflowStore, activity: activity),
        ]
        appliers.append(contentsOf: makeVOSpaceAppliers(
            service: vospace,
            observationStore: observationStore,
            appState: self,
            activity: activity
        ))
        let sessionAppliers: [any ProposalApplier] = [
            LaunchSessionApplier(service: sessionService,
                                  recentLaunchStore: recentLaunchStore,
                                  activity: activity),
            DeleteSessionApplier(service: sessionService, activity: activity),
            DeleteSessionsBulkApplier(service: sessionService, activity: activity),
            ClearResearchArchiveApplier(store: observationStore, activity: activity),
            RunCodeApplier(
                service: sessionService,
                vospace: vospace,
                username: { [weak self] in
                    guard let self else { return "" }
                    return await self.username
                },
                registryAuth: { [weak self] in
                    guard let self else { return nil }
                    return await self.aiComputeSettings.registryCredentials()
                },
                activity: activity),
            // Explicit pre-warm/sizing — same deps as RunCodeApplier so a
            // private compute image still pulls at cold-launch.
            StartComputeApplier(
                service: sessionService,
                vospace: vospace,
                username: { [weak self] in
                    guard let self else { return "" }
                    return await self.username
                },
                registryAuth: { [weak self] in
                    guard let self else { return nil }
                    return await self.aiComputeSettings.registryCredentials()
                },
                activity: activity),
            // Teardown — needs only the session service (delete-by-name).
            StopComputeApplier(service: sessionService, activity: activity),
            LaunchHeadlessJobApplier(
                service: headlessService,
                recentLaunchStore: recentLaunchStore,
                activity: activity,
                // Auto-stage long inline scripts to VOSpace under
                // `~/.verbinal-scripts/`. Injected here because
                // the auth-scoped vospace + username live in
                // `AppState`; the applier struct itself stays
                // Sendable + pure-by-construction.
                vospace: vospace,
                username: { [weak self] in
                    guard let self else { return "" }
                    return await self.username
                }
            ),
        ]
        appliers.append(contentsOf: sessionAppliers)

        // Image-discovery applier: routes to whatever
        // ImageDiscoveryCoordinator is current at apply time. The
        // coordinator is auth-scoped (created in
        // `afterAuthenticated`, nil before login); the resolver
        // captures `self` weakly so unauthenticated apply attempts
        // surface a clean error.
        // `AppState` is @MainActor, so reading `imageDiscoveryCoordinator`
        // from this non-MainActor closure already implies an actor hop —
        // the explicit `MainActor.run { self?... }` was redundant and
        // tripped the "self captured twice in concurrent code" warning.
        let imageDiscoveryApplier = DiscoverImagePackagesApplier(
            resolveCoordinator: { [weak self] in
                await self?.imageDiscoveryCoordinator
            },
            activity: activity
        )
        appliers.append(imageDiscoveryApplier)
        appliers.append(ClearProbeFailuresApplier(
            resolveCoordinator: { [weak self] in
                await self?.imageDiscoveryCoordinator
            },
            activity: activity))

        // Parity batch: renewal, exports, arbitrary-file upload, FITS
        // bookmarks. Capabilities captured here (MainActor) so the
        // Sendable applier closures never touch `self` off-actor except
        // through explicit hops.
        let sessionSvc = sessionService
        appliers.append(RenewSessionApplier(
            renew: { id in try await sessionSvc.renewSession(id: id) },
            activity: activity))
        appliers.append(ExportSearchResultsApplier(
            run: { [weak self] format, adql, maxRecords in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                return try await self.runSearchExport(format: format, adql: adql, maxRecords: maxRecords)
            },
            activity: activity))
        appliers.append(UploadFileToVOSpaceApplier(
            upload: { [weak self] fileURL, remotePath in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let user = await self.username
                guard !user.isEmpty else { throw ProposalApplyError.backendError("Sign in to CADC first") }
                try await vospace.uploadFile(username: user, remotePath: remotePath, fileURL: fileURL)
            },
            activity: activity))
        appliers.append(ExportResearchBundleApplier(
            run: { [weak self] includeCopies, uploadVOSpace in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                try await self.runResearchBundleExport(
                    includeFileCopies: includeCopies,
                    uploadToVOSpace: uploadVOSpace,
                    vospace: vospace,
                    observationStore: observationStore,
                    noteStore: noteStore
                )
            },
            activity: activity))
        appliers.append(SaveFITSBookmarkApplier(
            save: { [weak self] label, ra, dec, attribution in
                guard let self else { return }
                await MainActor.run {
                    // Attach to the active tab's file so the panel's
                    // per-file filter shows it; a global bookmark (no
                    // viewer open) keeps an empty source path.
                    let sourcePath = self.fitsTabHost.activeTab?.fileURL?.path ?? ""
                    self.fitsBookmarks.save(CoordinateBookmark(
                        label: label, ra: ra, dec: dec, sourceFilePath: sourcePath,
                        agentAttribution: attribution))
                }
            },
            activity: activity))
        appliers.append(DeleteFITSBookmarkApplier(
            delete: { [weak self] id in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                try await MainActor.run {
                    guard let uuid = UUID(uuidString: id),
                          let existing = self.fitsBookmarks.bookmarks.first(where: { $0.id == uuid }) else {
                        throw ProposalApplyError.backendError("bookmark not found: \(id)")
                    }
                    self.fitsBookmarks.delete(existing)
                }
            },
            activity: activity))
        appliers.append(OpenVOSpaceFileApplier(
            openFile: { [weak self] path in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let user = await self.username
                guard !user.isEmpty else { throw ProposalApplyError.backendError("Sign in to CADC first") }
                let (tempURL, _) = try await vospace.downloadFile(username: user, path: path)
                let name = tempURL.lastPathComponent
                switch try await self.openAstronomyFITSAwaitingChoice(url: tempURL) {
                case .awaitingViewerChoice: return AppState.viewerChoiceAgentNote(filename: name)
                case .loading(let viewer): return AppState.stillLoadingAgentNote(filename: name, viewer: viewer)
                case .opened: return nil
                }
            },
            activity: activity))
        appliers.append(SetVOSpaceACLApplier(
            set: { [weak self] path, groupRead, groupWrite, isPublic in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let user = await self.username
                guard !user.isEmpty else { throw ProposalApplyError.backendError("Sign in to CADC first") }
                try await vospace.setNodeACL(
                    username: user, path: path,
                    groupRead: groupRead, groupWrite: groupWrite, isPublic: isPublic)
            },
            activity: activity))
        appliers.append(ExportCubeFigureApplier(
            run: { [weak self] scale in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                return try await MainActor.run {
                    self.navigateTo(.cubeViewer)
                    return try exportCubeFigureHeadless(model: self.cubeViewer, scale: CGFloat(scale)).path
                }
            },
            activity: activity))
        appliers.append(ExportFITSFigureApplier(
            run: { [weak self] scale in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                return try await MainActor.run {
                    guard let tab = self.fitsTabHost.activeTab else {
                        throw ProposalApplyError.backendError("No FITS tab is open")
                    }
                    return try exportFITSFigureHeadless(model: tab, scale: CGFloat(scale)).path
                }
            },
            activity: activity))
        appliers.append(contentsOf: makeAIGuideAppliers(activity: activity))

        // Recent-searches writes — mutate the live store inside the
        // hoisted search model (same instance the side panel renders).
        let recentStore = searchModel.recentSearchStore
        appliers.append(RenameRecentSearchApplier(store: recentStore, activity: activity))
        appliers.append(RemoveRecentSearchApplier(store: recentStore, activity: activity))
        appliers.append(ClearRecentSearchesApplier(store: recentStore, activity: activity))

        agentsService.register(appliers: appliers)
    }
}
