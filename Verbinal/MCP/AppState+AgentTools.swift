// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Composes the canfar-mac MCP tool surface from `AppState`'s services.
///
/// Each tool here is constructed with the *minimal* set of capabilities
/// it needs — never the whole `AppState`. That keeps tool tests trivial:
/// inject stubs for the closures and call `invoke` directly.
extension AppState {
    func makeAgentTools() -> [any AITool] {
        var tools: [any AITool] = []

        // Foundational
        tools.append(DescribeAppTool())
        tools.append(makeGetAuthStateTool())
        tools.append(makeGetCurrentViewTool())

        // Search domain
        let tap = TAPClient()
        let resolver = TargetResolverService(tapClient: tap)
        let caom2 = CAOM2Service()
        let recentStore = RecentSearchStore()
        let savedStore = SavedQueryStore()

        tools.append(makeSearchObservationsTool(tap: tap, resolver: resolver))
        tools.append(makeVizierConeSearchTool(tap: tap))
        tools.append(makeResolveTargetTool(resolver: resolver))
        tools.append(makeGetObservationCAOM2Tool(caom2: caom2))
        tools.append(makeGetDataLinksTool(tap: tap, caom2: caom2))
        tools.append(makeGetPreviewImageTool(network: network, caom2: caom2))
        tools.append(makeListRecentSearchesTool(store: recentStore))
        tools.append(makeListSavedQueriesTool(store: savedStore))
        tools.append(makeGetSavedQueryTool(store: savedStore))

        // Research domain
        let observationStore = ObservationStore(spotlight: nil)  // tools don't drive Spotlight
        let noteStore = ObservationNoteStore()
        tools.append(makeListDownloadedObservationsTool(store: observationStore))
        tools.append(makeGetDownloadedObservationTool(store: observationStore))
        tools.append(makeGetObservationNotesTool(store: noteStore))

        // VOSpace domain
        let vospace = VOSpaceBrowserService(network: network, endpoints: endpoints)
        tools.append(makeListVOSpacePathTool(service: vospace))
        tools.append(makeGetVOSpaceNodeTool(service: vospace))
        tools.append(makeReadVOSpaceFileTool(service: vospace))

        // Service health — no auth needed; probes upstream
        // reachability for CADC/VOSpace/Skaha/VizieR.
        tools.append(GetServiceHealthTool(probe: {
            await GetServiceHealthTool.runCanonicalProbes()
        }))

        // Sessions domain
        let recentLaunchStore = RecentLaunchStore()
        tools.append(makeListSessionsTool())
        tools.append(makeGetSessionTool())
        tools.append(ListSessionTypesTool())
        tools.append(makeListSessionImagesTool())
        tools.append(makeListRecentLaunchesTool(store: recentLaunchStore))

        // Headless / batch domain — read + write
        tools.append(makeListHeadlessJobsTool())
        tools.append(makeGetHeadlessJobTool())
        tools.append(makeGetHeadlessJobLogsTool())
        tools.append(makeGetHeadlessJobEventsTool())
        tools.append(LaunchHeadlessJobTool())

        // Image discovery — local cache search + on-demand probing
        tools.append(makeFindImagesWithPackagesTool())
        tools.append(DiscoverImagePackagesTool())

        // FITS domain — uses the already-instantiated observationStore
        tools.append(makeGetFITSHeaderTool(store: observationStore))
        tools.append(makeGetFITSWCSTool(store: observationStore))

        // Write tools — saved queries + observation notes
        tools.append(SaveQueryTool())
        tools.append(UpdateSavedQueryTool())
        tools.append(DeleteSavedQueryTool())
        tools.append(UpdateObservationNoteTool())
        tools.append(BulkUpdateObservationNotesTool())

        // Write tools — downloads
        tools.append(DownloadObservationTool())
        tools.append(DownloadObservationsBulkTool())
        tools.append(DeleteDownloadedObservationTool())

        // Write tools — VOSpace
        tools.append(UploadToVOSpaceTool())
        tools.append(UploadTextToVOSpaceTool())
        tools.append(ClearUserSiteTool())
        tools.append(DownloadFromVOSpaceTool())
        tools.append(VOSpaceMkdirTool())
        tools.append(DeleteVOSpaceNodeTool())

        // Write tools — Sessions + archive maintenance
        tools.append(LaunchSessionTool())
        tools.append(DeleteSessionTool())
        tools.append(DeleteSessionsBulkTool())
        tools.append(ClearResearchArchiveTool())

        // AI remote compute — run code on a warm `contributed` session
        // via the /arc file-drop. `run_code` is an auto-apply-gated write
        // (drops the request into the inbox); `run_code_output` reads the
        // result back. Disabled until an AI compute image is set in
        // Settings ▸ Compute.
        tools.append(RunCodeTool())
        tools.append(makeRunCodeOutputTool(service: vospace))

        // View-state tools — live-applied, no proposal.
        tools.append(makeOpenFITSFileTool(store: observationStore))
        tools.append(makeSetSearchFocusTool())
        tools.append(makeNavigateToTool())

        // Proposal-lifecycle tools — operate on the queue itself.
        tools.append(ListPendingProposalsTool())
        tools.append(GetProposalStateTool())
        tools.append(WithdrawProposalTool())
        tools.append(ListEventsTool())

        registerWriteAppliers(savedQueryStore: savedStore,
                              noteStore: noteStore,
                              observationStore: observationStore,
                              vospace: vospace)

        return tools
    }

    // MARK: - AI remote compute

    /// `run_code_output` reads the watcher's result file back over the
    /// ARC REST API. A 404 means "not produced yet" (the session is still
    /// provisioning/executing) → surface as nil so the tool reports
    /// `ready:false` rather than an error.
    private func makeRunCodeOutputTool(service: VOSpaceBrowserService) -> RunCodeOutputTool {
        RunCodeOutputTool(fetchOut: { [weak self] path, maxBytes in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let username = await self.username
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            do {
                let result = try await service.fetchBytes(
                    username: username, path: path, offset: 0, maxBytes: maxBytes)
                return result.data
            } catch let e as NetworkError {
                switch e {
                case .httpError(404, _):
                    return nil   // result not written yet
                case .unauthorized, .httpError(401, _), .httpError(403, _):
                    throw ToolFailureReason.authRequired
                default:
                    throw ToolFailureReason.backendError("run_code_output read failed: \(e.localizedDescription)")
                }
            }
        })
    }

    // MARK: - View-state factories

    private func makeOpenFITSFileTool(store: ObservationStore) -> OpenFITSFileTool {
        let activity = agentsService.activityStore
        return OpenFITSFileTool(openFITS: { [weak self] id in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let obs = await MainActor.run { store.observations.first(where: { $0.id == id }) }
            guard let obs else {
                throw ToolFailureReason.unknownTarget("downloaded_observation \(id)")
            }
            guard obs.fileExists else {
                throw ToolFailureReason.backendError("local file missing: \(obs.localPath)")
            }
            // Resolve via security-scoped bookmark when present, then
            // publish onto AppState — `open(fitsURL:)` already exists
            // and routes the URL into the FITS viewer tab host.
            let url: URL
            if let bookmark = obs.bookmarkData {
                var stale = false
                do {
                    url = try URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  bookmarkDataIsStale: &stale)
                } catch {
                    throw ToolFailureReason.backendError("bookmark: \(error.localizedDescription)")
                }
            } else {
                url = obs.localURL
            }
            // View-state ops don't run through the proposal flow, so
            // we don't have an `OperationOrigin` from a context. Fall
            // back to a synthetic external origin tagged with the
            // tool name — the activity feed surfaces it as a "live"
            // entry so the user sees the breadcrumb even though no
            // proposal was queued.
            let origin: OperationOrigin = .external(clientID: "open_fits_file")
            await MainActor.run {
                // Bug from the 2026-04-30 astronomer workflow review:
                // setting `pendingFITSURL` alone wasn't enough — the
                // task that consumes it only fires while the FITS
                // viewer is mounted, so a user on Landing/Search never
                // saw the file appear. Navigate explicitly so the
                // agent's "open this file" intent is honoured even
                // when the user is on a different mode.
                if self.currentMode != .fitsViewer {
                    self.navigateTo(.fitsViewer)
                }
                self.pendingFITSURL = url
                activity.append(.live(
                    kind: "open_fits_file",
                    summary: "Opened FITS file: \(obs.observationID) (\(obs.collection))",
                    origin: origin
                ))
            }
            return (observationID: obs.observationID, localPath: obs.localPath)
        })
    }

    private func makeSetSearchFocusTool() -> SetSearchFocusTool {
        let activity = agentsService.activityStore
        return SetSearchFocusTool(apply: { [weak self] ra, dec in
            guard let self else { return }
            await MainActor.run {
                self.pendingSearchCoordinate = AppState.PendingCoordinate(ra: ra, dec: dec)
                activity.append(.live(
                    kind: "set_search_focus",
                    summary: String(format: "Focused search on (%.4f°, %+0.4f°)", ra, dec),
                    origin: .external(clientID: "set_search_focus")
                ))
            }
        })
    }

    private func makeNavigateToTool() -> NavigateToTool {
        let activity = agentsService.activityStore
        return NavigateToTool(navigate: { [weak self] mode in
            guard let self else { return }
            await MainActor.run {
                self.navigateTo(mode)
                activity.append(.live(
                    kind: "navigate_to",
                    summary: "Navigated to \(AppState.modeTitle(mode))",
                    origin: .external(clientID: "navigate_to")
                ))
            }
        })
    }

    /// Build and register the appliers that the proposal strip dispatches
    /// to. Stores are passed in so the same instance the read tools see
    /// is what the appliers mutate.
    private func registerWriteAppliers(savedQueryStore: SavedQueryStore,
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
        agentsService.register(appliers: appliers)
    }

    // MARK: - Sessions domain

    private func makeListSessionsTool() -> ListSessionsTool {
        ListSessionsTool(fetchAll: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let raw = try await self.sessionService.getSessions()
            return raw.map(Self.flatten)
        })
    }

    private func makeGetSessionTool() -> GetSessionTool {
        GetSessionTool(fetchAll: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let raw = try await self.sessionService.getSessions()
            return raw.map(Self.flatten)
        })
    }

    private func makeListSessionImagesTool() -> ListSessionImagesTool {
        // Capture the existing ImageService — it already targets the
        // user-scoped Skaha catalogue and reuses the auth-aware
        // NetworkClient. Returning the raw (id, types) tuples keeps
        // the tool's Output struct decoupled from the model layer.
        let service = self.imageService
        return ListSessionImagesTool(fetch: {
            let raw = try await service.getImages()
            return raw.map { (id: $0.id, types: $0.types) }
        })
    }

    // MARK: - Headless / batch domain factories

    private func makeListHeadlessJobsTool() -> ListHeadlessJobsTool {
        let service = self.headlessService
        return ListHeadlessJobsTool(fetch: {
            try await service.getHeadlessJobs()
        })
    }

    private func makeGetHeadlessJobTool() -> GetHeadlessJobTool {
        let service = self.headlessService
        return GetHeadlessJobTool(fetch: {
            try await service.getHeadlessJobs()
        })
    }

    private func makeGetHeadlessJobLogsTool() -> GetHeadlessJobLogsTool {
        let service = self.headlessService
        return GetHeadlessJobLogsTool(fetch: { id in
            try await service.getLogs(id: id)
        })
    }

    private func makeGetHeadlessJobEventsTool() -> GetHeadlessJobEventsTool {
        let service = self.headlessService
        return GetHeadlessJobEventsTool(fetch: { id in
            try await service.getEvents(id: id)
        })
    }

    // MARK: - Image-discovery factories

    private func makeFindImagesWithPackagesTool() -> FindImagesWithPackagesTool {
        // Three closures because the tool needs three orthogonal
        // signals from app state: query the cache, snapshot the
        // live catalogue (id + types for filtering), enumerate
        // what's been probed. All auth-scoped; pre-auth returns
        // empty for everything, which keeps the response shape
        // stable for the agent.
        return FindImagesWithPackagesTool(
            search: { [weak self] query in
                guard let coord = await self?.imageDiscoveryCoordinator else { return [] }
                return await coord.search(query)
            },
            catalogue: { [weak self] in
                guard let self else { return [] }
                do {
                    let raw = try await self.imageService.getImages()
                    return raw.map { (id: $0.id, types: $0.types) }
                } catch {
                    // Catalogue endpoint flaky: derive a
                    // synthetic catalogue from the cached
                    // manifests. Loses the `types` info (we
                    // don't store image type per manifest), so
                    // type-filtered queries silently match
                    // nothing — acceptable degraded mode, the
                    // alternative is failing the whole call.
                    let ids = await self.imageDiscoveryCoordinator?.knownImages() ?? []
                    return ids.map { (id: $0, types: []) }
                }
            },
            discoveredIDs: { [weak self] in
                await self?.imageDiscoveryCoordinator?.knownImages() ?? []
            },
            searchPartial: { [weak self] query, minScore, limit in
                guard let coord = await self?.imageDiscoveryCoordinator else { return [] }
                return await coord.searchPartial(query, minScore: minScore, limit: limit)
            }
        )
    }

    private func makeListRecentLaunchesTool(store: RecentLaunchStore) -> ListRecentLaunchesTool {
        ListRecentLaunchesTool(snapshot: { @MainActor in
            store.launches.map {
                RecentLaunchOut(
                    id: $0.id.uuidString, name: $0.name, type: $0.type,
                    image: $0.image, project: $0.project,
                    resourceType: $0.resourceType,
                    cores: $0.cores, ram: $0.ram, gpus: $0.gpus,
                    launchedAt: $0.launchedAt
                )
            }
        })
    }

    // Pure data-shape transform — no actor state. `nonisolated`
    // lets it be passed to `map` from any context, closing the
    // "@MainActor function value losing global actor" warnings
    // at every map call site that used to require a MainActor hop.
    private nonisolated static func flatten(_ s: Session) -> SessionOut {
        SessionOut(
            id: s.id, name: s.sessionName, type: s.sessionType,
            status: s.status, image: s.containerImage,
            connectURL: s.connectUrl,
            startedTime: s.startedTime, expiresTime: s.expiresTime,
            memoryAllocated: s.memoryAllocated, memoryUsage: s.memoryUsage,
            cpuAllocated: s.cpuAllocated, cpuUsage: s.cpuUsage,
            gpuAllocated: s.gpuAllocated
        )
    }

    // MARK: - FITS domain

    private func makeGetFITSHeaderTool(store: ObservationStore) -> GetFITSHeaderTool {
        GetFITSHeaderTool(resolve: { id in
            try await Self.resolveFITS(id: id, store: store)
        })
    }

    private func makeGetFITSWCSTool(store: ObservationStore) -> GetFITSWCSTool {
        GetFITSWCSTool(resolve: { id in
            try await Self.resolveFITS(id: id, store: store)
        })
    }

    /// Open the local FITS file for a downloaded observation, parse it,
    /// and return the snapshot. Honours the security-scoped bookmark if
    /// present so a sandboxed app can read user-selected paths.
    private static func resolveFITS(id: UUID, store: ObservationStore) async throws -> ResolvedFITS? {
        guard let obs = await MainActor.run(body: { store.observations.first(where: { $0.id == id }) }) else {
            return nil
        }
        guard obs.fileExists else {
            throw ToolFailureReason.backendError("local file missing: \(obs.localPath)")
        }
        let url: URL
        var didStart = false
        if let bookmark = obs.bookmarkData {
            var stale = false
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                didStart = url.startAccessingSecurityScopedResource()
            } catch {
                throw ToolFailureReason.backendError("bookmark resolution: \(error.localizedDescription)")
            }
        } else {
            url = obs.localURL
        }
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let file = try FITSParser.parse(url: url)
            return ResolvedFITS(observationID: obs.observationID, file: file)
        } catch {
            throw ToolFailureReason.backendError("FITS parse: \(error.localizedDescription)")
        }
    }

    // MARK: - VOSpace domain

    private func makeListVOSpacePathTool(service: VOSpaceBrowserService) -> ListVOSpacePathTool {
        ListVOSpacePathTool(listNodes: { [weak self] path, limit in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            // `self.username` is a @MainActor property; direct
            // `await` does the actor hop without the redundant
            // `MainActor.run { self.username }` wrapper that
            // tripped the strict-concurrency check.
            let username = await self.username
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            let nodes = try await service.listNodes(username: username, path: path, limit: limit)
            return nodes.map(Self.flatten)
        })
    }

    private func makeGetVOSpaceNodeTool(service: VOSpaceBrowserService) -> GetVOSpaceNodeTool {
        GetVOSpaceNodeTool(listNodes: { [weak self] path, limit in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            // `self.username` is a @MainActor property; direct
            // `await` does the actor hop without the redundant
            // `MainActor.run { self.username }` wrapper that
            // tripped the strict-concurrency check.
            let username = await self.username
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            let nodes = try await service.listNodes(username: username, path: path, limit: limit)
            return nodes.map(Self.flatten)
        })
    }

    private func makeReadVOSpaceFileTool(service: VOSpaceBrowserService) -> ReadVOSpaceFileTool {
        ReadVOSpaceFileTool(fetch: { [weak self] path, offset, maxBytes in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let username = await self.username
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            let result = try await service.fetchBytes(
                username: username,
                path: path,
                offset: offset,
                maxBytes: maxBytes
            )
            return ReadVOSpaceFetchResult(data: result.data, totalBytes: result.totalBytes)
        })
    }

    private nonisolated static func flatten(_ node: VOSpaceNode) -> VOSpaceNodeOut {
        VOSpaceNodeOut(
            name: node.name,
            path: node.path,
            type: node.type.rawValue,
            sizeBytes: node.sizeBytes,
            contentType: node.contentType,
            lastModified: node.lastModified,
            isPublic: node.isPublic
        )
    }

    // MARK: - Research domain

    private func makeListDownloadedObservationsTool(store: ObservationStore) -> ListDownloadedObservationsTool {
        ListDownloadedObservationsTool(snapshot: { @MainActor in
            store.observations.map { Self.flatten($0) }
        })
    }

    private func makeGetDownloadedObservationTool(store: ObservationStore) -> GetDownloadedObservationTool {
        GetDownloadedObservationTool(lookup: { @MainActor id in
            store.observations.first(where: { $0.id == id }).map { Self.flatten($0) }
        })
    }

    private func makeGetObservationNotesTool(store: ObservationNoteStore) -> GetObservationNotesTool {
        GetObservationNotesTool(lookup: { @MainActor pid in
            guard let note = store.note(for: pid) else { return nil }
            return ObservationNoteOut(
                publisherID: note.publisherID,
                text: note.text,
                rating: note.rating,
                tags: note.tags,
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt,
                isEmpty: note.isEmpty
            )
        })
    }

    private nonisolated static func flatten(_ obs: DownloadedObservation) -> DownloadedObservationOut {
        DownloadedObservationOut(
            id: obs.id.uuidString,
            publisherID: obs.publisherID,
            collection: obs.collection,
            observationID: obs.observationID,
            targetName: obs.targetName,
            instrument: obs.instrument,
            filter: obs.filter,
            calLevel: obs.calLevel,
            localPath: obs.localPath,
            fileExists: obs.fileExists,
            fileSize: obs.fileSize,
            downloadedAt: obs.downloadedAt
        )
    }

    // MARK: - Foundational

    private func makeGetCurrentViewTool() -> GetCurrentViewTool {
        // Body extracted to an instance @MainActor method below.
        // Closure captures `self` weakly; if `self` is gone the
        // snapshot falls back to a "no app" default. Reads better
        // than nesting two `[weak self]` MainActor.run blocks and
        // closes the strict-concurrency warning about `self` being
        // captured twice across actor hops.
        return GetCurrentViewTool(snapshot: { [weak self] in
            await self?.snapshotCurrentView() ?? Self.unknownCurrentViewOutput
        })
    }

    @MainActor
    fileprivate func snapshotCurrentView() -> GetCurrentViewTool.Output {
        GetCurrentViewTool.Output(
            mode: Self.modeKey(currentMode),
            modeTitle: Self.modeTitle(currentMode),
            isAuthenticated: isAuthenticated,
            username: username,
            searchFocusRA: pendingSearchCoordinate?.ra,
            searchFocusDec: pendingSearchCoordinate?.dec,
            openFITSPaths: pendingFITSURL.map { [$0.path] } ?? [],
            pendingProposalsCount: agentsService.pendingProposals.count,
            agentsEnabled: agentsService.isEnabled,
            autoApplyEnabled: agentsService.autoApplyWrites,
            followAgentActivityEnabled: agentsService.followAgentActivity
        )
    }

    // Immutable defaults; `nonisolated` so the snapshot closure
    // can read them without an actor hop on the "self is gone"
    // fallback path.
    nonisolated fileprivate static let unknownCurrentViewOutput = GetCurrentViewTool.Output(
        mode: "unknown", modeTitle: "Unknown",
        isAuthenticated: false, username: "",
        searchFocusRA: nil, searchFocusDec: nil,
        openFITSPaths: [],
        pendingProposalsCount: 0,
        agentsEnabled: false,
        autoApplyEnabled: false,
        followAgentActivityEnabled: false
    )

    private static func modeKey(_ mode: AppMode) -> String {
        switch mode {
        case .landing:    return "landing"
        case .search:     return "search"
        case .research:   return "research"
        case .portal:     return "portal"
        case .storage:    return "storage"
        case .fitsViewer: return "fitsViewer"
        }
    }

    static func modeTitle(_ mode: AppMode) -> String {
        switch mode {
        case .landing:    return "Landing"
        case .search:     return "Search"
        case .research:   return "Research"
        case .portal:     return "Portal"
        case .storage:    return "Storage"
        case .fitsViewer: return "FITS Viewer"
        }
    }

    private func makeGetAuthStateTool() -> GetAuthStateTool {
        // Same extract-to-method pattern as `makeGetCurrentViewTool`.
        return GetAuthStateTool(snapshot: { [weak self] in
            await self?.snapshotAuthState() ?? Self.unknownAuthStateOutput
        })
    }

    @MainActor
    fileprivate func snapshotAuthState() -> GetAuthStateTool.Output {
        let info = userInfo
        let display: String? = {
            guard let info else { return nil }
            let parts = [info.firstName, info.lastName].compactMap { $0 }
            let combined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return combined.isEmpty ? nil : combined
        }()
        return GetAuthStateTool.Output(
            isAuthenticated: isAuthenticated,
            username: username,
            displayName: display
        )
    }

    nonisolated fileprivate static let unknownAuthStateOutput = GetAuthStateTool.Output(
        isAuthenticated: false,
        username: "",
        displayName: nil
    )

    // MARK: - Search domain

    private func makeSearchObservationsTool(tap: TAPClient,
                                            resolver: TargetResolverService) -> SearchObservationsTool {
        SearchObservationsTool(
            runQuery: { adql, maxRec in
                try await tap.tapQueryRows(adql: adql, maxRec: maxRec)
            },
            resolveTarget: { name in
                let result = try await resolver.resolve(target: name, service: .all)
                // CADC's resolver returns RA/Dec as strings — usually
                // decimal degrees but some shapes ship sexagesimal.
                // Try Double() first; fall back to the sexagesimal
                // parsers from FITSWCSTransform. Trailing CR/LF is
                // already stripped by the resolver parser (F-12 fix in
                // TAPClient.parseResolverResponse), so a clean
                // numeric string here means we genuinely failed to
                // resolve. (Closes F-9 of the platform review.)
                let ra: Double
                let dec: Double
                if let r = Double(result.coordsRA), let d = Double(result.coordsDec) {
                    ra = r
                    dec = d
                } else if let r = FITSWCSTransform.parseRA(result.coordsRA),
                          let d = FITSWCSTransform.parseDec(result.coordsDec) {
                    ra = r
                    dec = d
                } else {
                    throw ToolFailureReason.targetNotResolved(name)
                }
                return (ra: ra, dec: dec)
            }
        )
    }

    private func makeVizierConeSearchTool(tap: TAPClient) -> VizierConeSearchTool {
        VizierConeSearchTool(search: { catalogue, ra, dec, radius, raCol, decCol, max in
            try await tap.vizierConeSearch(
                catalogue: catalogue,
                raDeg: ra, decDeg: dec, radiusDeg: radius,
                raColumn: raCol, decColumn: decCol,
                maxRec: max
            )
        })
    }

    private func makeResolveTargetTool(resolver: TargetResolverService) -> ResolveTargetTool {
        ResolveTargetTool(resolve: { name, service in
            let svc = ResolverValue(rawValue: service) ?? .all
            let r: ResolverResult
            do {
                r = try await resolver.resolve(target: name, service: svc)
            } catch {
                // CADC's resolver returns non-200 for unknown names
                // and moving solar-system bodies (Europa, Io, …),
                // which `TAPClient.resolveTarget` surfaces as
                // `SearchError.networkError`. Re-tag that as
                // `targetNotResolved` so agents can distinguish
                // "name not in resolver" from "the network is down"
                // — which is exactly what the verbinal-canfar QA
                // pass flagged.
                if case SearchError.networkError = error {
                    throw ToolFailureReason.targetNotResolved(name)
                }
                throw error
            }
            // Resolver-said-OK-but-no-coords. Coordinates may arrive
            // either as plain decimal degrees or sexagesimal strings;
            // try both. If neither parses we treat the target as
            // unresolved, mirroring the SearchObservationsTool path.
            let raDeg = Double(r.coordsRA) ?? FITSWCSTransform.parseRA(r.coordsRA)
            let decDeg = Double(r.coordsDec) ?? FITSWCSTransform.parseDec(r.coordsDec)
            if raDeg == nil || decDeg == nil {
                throw ToolFailureReason.targetNotResolved(name)
            }
            return ResolveTargetTool.Output(
                target: r.target,
                service: r.service,
                raDeg: raDeg,
                decDeg: decDeg,
                raString: r.coordsRA,
                decString: r.coordsDec,
                coordsys: r.coordsys,
                objectType: r.objectType,
                morphologyType: r.morphologyType
            )
        })
    }

    private func makeGetObservationCAOM2Tool(caom2: CAOM2Service) -> GetObservationCAOM2Tool {
        GetObservationCAOM2Tool(fetch: { id in
            try await caom2.fetch(publisherID: id)
        })
    }

    private func makeGetDataLinksTool(tap: TAPClient, caom2: CAOM2Service) -> GetDataLinksTool {
        GetDataLinksTool(fetch: { id in
            // Applier-level 30-second wall-clock deadline scoped to
            // the DataLink fetch ONLY. This is the inner of two
            // independent watchdogs (the outer one is the tool-level
            // `GetDataLinksTool.toolTimeoutSeconds == 30`, applied by
            // `JSONReadTool.invoke` around the whole `handle`). The
            // QA review of 2026-05-14 documented a 4-minute silent
            // hang here — same failure class as the upload applier
            // F-2026-05-13-A: the network call neither returns nor
            // throws, so the caller can't distinguish "still working"
            // from "stuck forever". This inner watchdog converts that
            // to a typed timeout error the wiring can react to before
            // the outer tool deadline fires — falling back to the
            // CAOM-2 inventory below, or letting the agent use the
            // per-artefact downloadURL pattern. Keep this 30s in sync
            // with `GetDataLinksTool.toolTimeoutSeconds`.
            let r = try await withApplierTimeout(seconds: 30, label: "get_data_links") {
                try await tap.fetchDataLinks(publisherID: id)
            }
            let files = r.directFiles.map {
                (url: $0.url, contentType: $0.contentType, filename: $0.filename,
                 isUncompressedFITS: $0.isUncompressedFITS)
            }

            // Always consult CAOM-2 for the full inventory. The
            // original design only filled `artifacts` when DataLink
            // was empty (fallback-only), but DataLink's `#this`
            // rows are a SUBSET of CAOM-2 — they're the directly-
            // downloadable URLs. The full record also lists
            // weight maps, previews, auxiliary products, and
            // provenance artefacts that DataLink suppresses. An
            // agent that already has `files` still benefits from
            // knowing what else the observation owns. Caching in
            // `CAOM2Service` (5-min LRU) makes the extra fetch
            // free on the second call. Failure-to-fetch is
            // tolerated: agents still get the DataLink URLs.
            var artifacts: [(uri: String, productType: String?, contentType: String?,
                             contentLength: Int64?, filename: String, downloadURL: URL?)] = []
            let endpoints = self.endpoints
            if let obs = try? await caom2.fetch(publisherID: id) {
                for plane in obs.planes {
                    for a in plane.artifacts {
                        let filename = (a.uri as NSString).lastPathComponent
                        artifacts.append((
                            uri: a.uri,
                            productType: a.productType,
                            contentType: a.contentType,
                            contentLength: a.contentLength,
                            filename: filename,
                            downloadURL: endpoints.dataPubURL(forArtifactURI: a.uri)
                        ))
                    }
                }
            }
            return (
                thumbnails: r.thumbnails,
                previews: r.previews,
                files: files,
                artifacts: artifacts,
                packageDownloadURL: TAPClient.downloadURL(publisherID: id)
            )
        })
    }

    private func makeGetPreviewImageTool(network: NetworkClient, caom2: CAOM2Service) -> GetPreviewImageTool {
        let endpoints = self.endpoints
        return GetPreviewImageTool(
            resolvePreviews: { id in
                // Resolve preview artifacts from the CAOM-2 inventory: each
                // plane carries its bandpass (energy.bandpassName) and its
                // artifacts; keep only previews (productType "preview" or an
                // image/* content type). Band lives in CAOM-2, NOT DataLink
                // rows (verified against IVOA DataLink 1.0). The per-artifact
                // dataPubURL 302-redirects to signed storage; the fetch follows.
                let obs = try await caom2.fetch(publisherID: id)
                var out: [GetPreviewImageTool.PreviewArtifact] = []
                for plane in obs.planes {
                    let band = plane.energy?.bandpassName
                    for a in plane.artifacts {
                        let isPreview = (a.productType?.lowercased() == "preview")
                            || (a.contentType?.lowercased().hasPrefix("image/") ?? false)
                        guard isPreview, let url = endpoints.dataPubURL(forArtifactURI: a.uri) else { continue }
                        out.append(.init(
                            band: band,
                            url: url,
                            contentType: a.contentType,
                            contentLength: a.contentLength,
                            filename: (a.uri as NSString).lastPathComponent
                        ))
                    }
                }
                return out
            },
            fetchImage: { url, maxBytes in
                // Inner watchdog scoped to the fetch only (mirrors get_data_links);
                // its deadline surfaces as a typed backendError naming the tool.
                try await withApplierTimeout(seconds: 30, label: "get_preview_image") {
                    do {
                        let (data, response) = try await network.get(url.absoluteString, accept: "image/*")
                        if data.count > maxBytes {
                            throw GetPreviewImageTool.PreviewFetchError.tooLarge(data.count)
                        }
                        return (data, response.value(forHTTPHeaderField: "Content-Type"))
                    } catch let e as GetPreviewImageTool.PreviewFetchError {
                        throw e
                    } catch let e as NetworkError {
                        switch e {
                        case .unauthorized:
                            throw GetPreviewImageTool.PreviewFetchError.authRequired
                        case .httpError(let code, _) where code == 401 || code == 403:
                            throw GetPreviewImageTool.PreviewFetchError.authRequired
                        case .httpError(let code, _):
                            throw GetPreviewImageTool.PreviewFetchError.http(code)
                        default:
                            throw GetPreviewImageTool.PreviewFetchError.transport(e.localizedDescription)
                        }
                    }
                }
            }
        )
    }

    private func makeListRecentSearchesTool(store: RecentSearchStore) -> ListRecentSearchesTool {
        ListRecentSearchesTool(snapshot: { @MainActor in
            store.searches.map { ($0.id, $0.name, $0.savedAt) }
        })
    }

    private func makeListSavedQueriesTool(store: SavedQueryStore) -> ListSavedQueriesTool {
        ListSavedQueriesTool(snapshot: { @MainActor in
            store.queries.map {
                SavedQueryRow(
                    id: $0.id, name: $0.name, adql: $0.adql,
                    savedAt: $0.savedAt,
                    description: $0.description, tags: $0.tags
                )
            }
        })
    }

    private func makeGetSavedQueryTool(store: SavedQueryStore) -> GetSavedQueryTool {
        GetSavedQueryTool(lookup: { @MainActor id in
            guard let q = store.queries.first(where: { $0.id == id }) else { return nil }
            return SavedQueryRow(
                id: q.id, name: q.name, adql: q.adql,
                savedAt: q.savedAt,
                description: q.description, tags: q.tags
            )
        })
    }
}
