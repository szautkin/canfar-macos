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
        tools.append(makeResolveTargetTool(resolver: resolver))
        tools.append(makeGetObservationCAOM2Tool(caom2: caom2))
        tools.append(makeGetDataLinksTool(tap: tap))
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
        tools.append(DownloadFromVOSpaceTool())
        tools.append(VOSpaceMkdirTool())
        tools.append(DeleteVOSpaceNodeTool())

        // Write tools — Sessions + archive maintenance
        tools.append(LaunchSessionTool())
        tools.append(DeleteSessionTool())
        tools.append(ClearResearchArchiveTool())

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
            ClearResearchArchiveApplier(store: observationStore, activity: activity),
            LaunchHeadlessJobApplier(service: headlessService,
                                      recentLaunchStore: recentLaunchStore,
                                      activity: activity),
        ]
        appliers.append(contentsOf: sessionAppliers)
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

    private static func flatten(_ s: Session) -> SessionOut {
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
            let username = await MainActor.run { self.username }
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            let nodes = try await service.listNodes(username: username, path: path, limit: limit)
            return nodes.map(Self.flatten)
        })
    }

    private func makeGetVOSpaceNodeTool(service: VOSpaceBrowserService) -> GetVOSpaceNodeTool {
        GetVOSpaceNodeTool(listNodes: { [weak self] path, limit in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let username = await MainActor.run { self.username }
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            let nodes = try await service.listNodes(username: username, path: path, limit: limit)
            return nodes.map(Self.flatten)
        })
    }

    private static func flatten(_ node: VOSpaceNode) -> VOSpaceNodeOut {
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

    private static func flatten(_ obs: DownloadedObservation) -> DownloadedObservationOut {
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
        GetCurrentViewTool(snapshot: { [weak self] in
            await MainActor.run {
                guard let s = self else {
                    return GetCurrentViewTool.Output(
                        mode: "unknown", modeTitle: "Unknown",
                        isAuthenticated: false, username: "",
                        searchFocusRA: nil, searchFocusDec: nil,
                        openFITSPaths: [],
                        pendingProposalsCount: 0,
                        agentsEnabled: false,
                        autoApplyEnabled: false,
                        followAgentActivityEnabled: false
                    )
                }
                let mode = Self.modeKey(s.currentMode)
                return GetCurrentViewTool.Output(
                    mode: mode,
                    modeTitle: Self.modeTitle(s.currentMode),
                    isAuthenticated: s.isAuthenticated,
                    username: s.username,
                    searchFocusRA: s.pendingSearchCoordinate?.ra,
                    searchFocusDec: s.pendingSearchCoordinate?.dec,
                    openFITSPaths: s.pendingFITSURL.map { [$0.path] } ?? [],
                    pendingProposalsCount: s.agentsService.pendingProposals.count,
                    agentsEnabled: s.agentsService.isEnabled,
                    autoApplyEnabled: s.agentsService.autoApplyWrites,
                    followAgentActivityEnabled: s.agentsService.followAgentActivity
                )
            }
        })
    }

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
        GetAuthStateTool(snapshot: { [weak self] in
            await MainActor.run {
                let s = self
                let info = s?.userInfo
                let display: String? = {
                    guard let info else { return nil }
                    let parts = [info.firstName, info.lastName].compactMap { $0 }
                    let combined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    return combined.isEmpty ? nil : combined
                }()
                return GetAuthStateTool.Output(
                    isAuthenticated: s?.isAuthenticated ?? false,
                    username: s?.username ?? "",
                    displayName: display
                )
            }
        })
    }

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

    private func makeResolveTargetTool(resolver: TargetResolverService) -> ResolveTargetTool {
        ResolveTargetTool(resolve: { name, service in
            let svc = ResolverValue(rawValue: service) ?? .all
            let r = try await resolver.resolve(target: name, service: svc)
            return ResolveTargetTool.Output(
                target: r.target,
                service: r.service,
                raDeg: Double(r.coordsRA),
                decDeg: Double(r.coordsDec),
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

    private func makeGetDataLinksTool(tap: TAPClient) -> GetDataLinksTool {
        GetDataLinksTool(fetch: { id in
            let r = try await tap.fetchDataLinks(publisherID: id)
            let files = r.directFiles.map {
                (url: $0.url, contentType: $0.contentType, filename: $0.filename,
                 isUncompressedFITS: $0.isUncompressedFITS)
            }
            return (thumbnails: r.thumbnails, previews: r.previews, files: files)
        })
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
