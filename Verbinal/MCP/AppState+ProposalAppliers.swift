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
        // One archive client for the downloads and the details they keep, so
        // a plane looked up for one is not fetched again for the other.
        let caom2 = CAOM2Service()
        let downloader = DownloadService(endpoints: endpoints, caom2: caom2)
        let describe: ResearchRecordDescriber = { [weak self] described in
            await self?.researchRecord(describing: described, caom2: caom2) ?? described
        }
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
                                       describe: describe,
                                       activity: activity),
            DownloadObservationsBulkApplier(downloadService: downloader,
                                            observationStore: observationStore,
                                            describe: describe,
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
            DeleteSessionApplier(delete: { [sessionActions] id in try await sessionActions.delete(id: id) },
                                 activity: activity),
            DeleteSessionsBulkApplier(deleteAll: { [sessionActions] ids in await sessionActions.delete(ids: ids) },
                                      activity: activity),
            ClearResearchArchiveApplier(store: observationStore, activity: activity),
            // Remote compute — all through the one service the Remote
            // Compute screen uses, so a run is remembered as the assistant's.
            RunCodeApplier(
                submit: { [weak self] request, launch in
                    guard let self else { throw ProposalApplyError.backendError("app state gone") }
                    return try await self.remoteCompute.submit(request, by: .agent, launch: launch)
                },
                activity: activity),
            StartComputeApplier(
                ensure: { [weak self] launch in
                    guard let self else { throw ProposalApplyError.backendError("app state gone") }
                    return try await self.remoteCompute.ensureSession(launch)
                },
                activity: activity),
            StopComputeApplier(
                stop: { [weak self] in
                    guard let self else { throw ProposalApplyError.backendError("app state gone") }
                    return try await self.remoteCompute.stop()
                },
                activity: activity),
            LaunchHeadlessJobApplier(
                service: headlessService,
                recentLaunchStore: recentLaunchStore,
                activity: activity,
                history: jobHistory,
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
        appliers.append(AddRegistryImageApplier(
            add: { [weak self] image in await self?.userImages.add(image) ?? false },
            activity: activity))
        appliers.append(RemoveRegistryImageApplier(
            remove: { [weak self] id in await self?.userImages.remove(id) ?? false },
            activity: activity))

        // Parity batch: renewal, exports, arbitrary-file upload, FITS
        // bookmarks. Capabilities captured here (MainActor) so the
        // Sendable applier closures never touch `self` off-actor except
        // through explicit hops.
        appliers.append(RenewSessionApplier(
            renew: { [sessionActions] id in try await sessionActions.renew(id: id) },
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
                guard let self else { return nil }
                return await MainActor.run {
                    // Attach to the active tab's file so the panel's
                    // per-file filter shows it; a global bookmark (no
                    // viewer open) keeps an empty source path.
                    let sourcePath = self.fitsTabHost.activeTab?.fileURL?.path ?? ""
                    let bookmark = CoordinateBookmark(
                        label: label, ra: ra, dec: dec, sourceFilePath: sourcePath,
                        agentAttribution: attribution)
                    self.fitsBookmarks.save(bookmark)
                    return bookmark.id
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
            run: { [weak self] request in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                return try await MainActor.run {
                    self.navigateTo(.cubeViewer)
                    let cube = self.cubeViewer
                    let marks = cube.markTarget.map { self.marks.marks(on: $0) } ?? []
                    return try exportCubeFigureHeadless(model: cube, request: request, marks: marks).path
                }
            },
            activity: activity))
        appliers.append(ExportFITSFigureApplier(
            run: { [weak self] request in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                return try await MainActor.run {
                    guard let tab = self.fitsTabHost.activeTab else {
                        throw ProposalApplyError.backendError("No FITS tab is open")
                    }
                    let marks = tab.markTarget.map { self.marks.marks(on: $0) } ?? []
                    return try exportFITSFigureHeadless(model: tab, request: request, marks: marks).path
                }
            },
            activity: activity))
        appliers.append(contentsOf: makeAIGuideAppliers(activity: activity))
        appliers.append(contentsOf: makeResearchRecordAppliers(describe: describe, activity: activity))
        appliers.append(contentsOf: makeCutoutAppliers(activity: activity))

        // Recent-searches writes — mutate the live store inside the
        // hoisted search model (same instance the side panel renders).
        let recentStore = searchModel.recentSearchStore
        appliers.append(RenameRecentSearchApplier(store: recentStore, activity: activity))
        appliers.append(RemoveRecentSearchApplier(store: recentStore, activity: activity))
        appliers.append(ClearRecentSearchesApplier(store: recentStore, activity: activity))

        agentsService.register(appliers: appliers)
    }
}
