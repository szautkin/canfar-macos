// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit
import MCPCore

/// Composes the canfar-mac MCP tool surface from `AppState`'s services.
///
/// Each tool here is constructed with the *minimal* set of capabilities
/// it needs — never the whole `AppState`. That keeps tool tests trivial:
/// inject stubs for the closures and call `invoke` directly.
///
/// This file is the composition root plus the app-wide reads (current view,
/// auth, navigation, endpoints). Each module's factories live in its own
/// `AppState+<Module>Tools.swift`.
extension AppState {
    func makeAgentTools() -> [any AITool] {
        var tools: [any AITool] = []

        // Foundational — and the map of everything below: the tool list
        // exactly as agents get it, read late (the server builds it).
        let published: @Sendable () async -> [ToolDefinitionWire] = { [weak self] in
            guard let service = self?.agentsService else { return [] }
            return await service.publishedTools()
        }
        var describeApp = DescribeAppTool()
        describeApp.published = published
        tools.append(describeApp)
        tools.append(ListAppsTool(published: published))
        tools.append(SearchToolsTool(published: published))
        tools.append(ManTool(published: published))
        tools.append(makeCopyToClipboardTool())
        tools.append(makeListUITargetsTool())
        tools.append(makePointAtUITool())
        tools.append(makeOpenSettingsTool())
        tools.append(makeCloseSettingsTool())
        tools.append(makeGetAuthStateTool())
        tools.append(makeGetCurrentViewTool())
        tools.append(ListActivityTool(tasks: { [weak self] in await self?.tasks.tasks ?? [] }))
        tools.append(ListJobHistoryTool(jobs: { [weak self] in await self?.jobHistory.jobs ?? [] }))

        // Search domain. The recent/saved stores are the LIVE instances
        // inside the hoisted `searchModel` — agent writes appear in the
        // side panel immediately, instead of landing in a shadow store
        // that only converges through the shared JSON file on relaunch.
        let tap = TAPClient()
        let resolver = TargetResolverService(tapClient: tap)
        let caom2 = CAOM2Service()
        let recentStore = searchModel.recentSearchStore
        let savedStore = searchModel.savedQueryStore

        tools.append(makeSearchObservationsTool(tap: tap, resolver: resolver))
        tools.append(makeVizierConeSearchTool(tap: tap))
        tools.append(makeResolveTargetTool(resolver: resolver))
        tools.append(makeGetObservationCAOM2Tool(caom2: caom2))
        tools.append(makeGetDataLinksTool(tap: tap, caom2: caom2))
        tools.append(makeGetPreviewImageTool(network: network, caom2: caom2))
        tools.append(makeListRecentSearchesTool(store: recentStore))
        tools.append(makeListSavedQueriesTool(store: savedStore))
        tools.append(makeGetSavedQueryTool(store: savedStore))

        // Research domain — live store shared with the Research UI so
        // ids downloaded last session (or via the UI) resolve after relaunch.
        let observationStore = researchModel.observationStore
        let noteStore = researchModel.noteStore
        tools.append(makeListDownloadedObservationsTool(store: observationStore))
        tools.append(makeGetDownloadedObservationTool(store: observationStore))
        tools.append(makeGetObservationNotesTool(store: noteStore))
        tools.append(makeListWorkflowsTool())
        tools.append(makeGetWorkflowTool())

        // VOSpace domain
        let vospace = VOSpaceBrowserService(network: network, endpoints: endpoints)
        tools.append(makeListVOSpacePathTool(service: vospace))
        tools.append(makeGetVOSpaceNodeTool(service: vospace))
        tools.append(makeReadVOSpaceFileTool(service: vospace))

        // Service health — no auth needed; probes upstream reachability for
        // the EFFECTIVE registry/archive/VOSpace/Skaha endpoints plus the
        // global VizieR mirrors (the canonical CANFAR list would report the
        // wrong backend when endpoints are overridden or resolved).
        let healthEndpoints = GetServiceHealthTool.deploymentEndpoints(for: endpoints)
        tools.append(GetServiceHealthTool(probe: {
            await GetServiceHealthTool.runCanonicalProbes(endpoints: healthEndpoints)
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

        // Sessions parity — the Events sheet, log view, and Connect button.
        tools.append(makeGetSessionEventsTool())
        tools.append(makeGetSessionLogsTool())
        tools.append(makeOpenSessionTool())

        // Image discovery — local cache search + on-demand probing
        tools.append(makeFindImagesWithPackagesTool())
        tools.append(DiscoverImagePackagesTool())

        // Image-discovery parity — the sheet's diagnostics: failure
        // rows, probe logs/events, cached manifests, clearing failures.
        tools.append(makeListProbeFailuresTool())
        tools.append(makeGetProbeLogsTool())
        tools.append(makeGetImageManifestTool())
        tools.append(ClearProbeFailuresTool())
        // What is inside probed images, and images the catalogue does not list.
        tools.append(makeSearchPackagesTool())
        tools.append(makeDescribeImageTool())
        tools.append(makeSearchImageRegistryTool())
        tools.append(makeListMyImagesTool())
        tools.append(AddRegistryImageTool())
        tools.append(makeRemoveRegistryImageTool())

        // FITS domain — uses the already-instantiated observationStore
        tools.append(makeGetFITSHeaderTool(store: observationStore))
        tools.append(makeGetFITSWCSTool(store: observationStore))

        // Write tools — saved queries + observation notes
        tools.append(SaveQueryTool())
        tools.append(UpdateSavedQueryTool())
        tools.append(DeleteSavedQueryTool())
        tools.append(UpdateObservationNoteTool())
        tools.append(BulkUpdateObservationNotesTool())
        tools.append(SaveWorkflowTool())
        tools.append(UpdateWorkflowTool())
        tools.append(SetWorkflowStepTool())
        tools.append(UseWorkflowTool())
        tools.append(DeleteWorkflowTool())

        // Write tools — downloads
        tools.append(DownloadObservationTool())
        tools.append(DownloadObservationsBulkTool())
        tools.append(DeleteDownloadedObservationTool())

        // Write tools — VOSpace
        tools.append(UploadToVOSpaceTool())
        tools.append(UploadTextToVOSpaceTool())
        tools.append(ClearUserSiteTool())
        let downloadVOSpace = DownloadFromVOSpaceTool()
        tools.append(downloadVOSpace)
        tools.append(AliasedToolBox(
            name: "download_from_vospace",
            description: "Alias of `download_vospace_file`.",
            inner: downloadVOSpace))
        let mkdirVOSpace = VOSpaceMkdirTool()
        tools.append(mkdirVOSpace)
        tools.append(AliasedToolBox(
            name: "vospace_mkdir",
            description: "Alias of `create_vospace_folder`.",
            inner: mkdirVOSpace))
        tools.append(DeleteVOSpaceNodeTool())
        tools.append(OpenVOSpaceFileTool())

        // Write tools — Sessions + archive maintenance
        tools.append(LaunchSessionTool())
        tools.append(DeleteSessionTool())
        tools.append(DeleteSessionsBulkTool())
        tools.append(ClearResearchArchiveTool())

        // AI remote compute — run code on a warm `contributed` session
        // via the /arc file-drop. `run_code` is an auto-apply-gated write
        // (drops the request into the inbox); `run_code_output` reads the
        // result back. Disabled until an AI compute image is set in
        // Settings ▸ AI Compute.
        tools.append(RunCodeTool())
        tools.append(makeRunCodeOutputTool())
        tools.append(makeGetComputeStateTool())
        tools.append(makeListComputeRunsTool())
        // The Remote Compute screen and Storage, put in front of the person.
        tools.append(makeGetComputeViewTool())
        tools.append(makeShowComputeRunTool())
        tools.append(makeSetComputeSnippetTool())
        tools.append(makeShowStorageFolderTool())
        // Explicit lifecycle on top of the lazy `run_code`: pre-warm /
        // size the instance (`start_compute`) and tear it down
        // (`stop_compute`). Resources are an instance property set on
        // start; `run_code` still self-launches at the Settings default.
        tools.append(StartComputeTool())
        tools.append(StopComputeTool())

        // Platform & quota reads — the dashboard widgets as tools.
        tools.append(makeGetPlatformLoadTool())
        tools.append(makeGetStorageQuotaTool())

        // Write tools — session renewal, exports, arbitrary-file upload,
        // FITS bookmarks (Windows-parity names).
        tools.append(RenewSessionTool())
        tools.append(ExportSearchResultsTool())
        tools.append(UploadFileToVOSpaceTool())
        tools.append(ExportResearchBundleTool())
        tools.append(SaveFITSBookmarkTool())
        tools.append(DeleteFITSBookmarkTool())
        tools.append(SetVOSpaceACLTool())
        tools.append(ExportCubeFigureTool())

        // AI Guide management — the AI Guide screen's actions as tools
        // (Windows parity). Proposal-gated like every other write.
        tools.append(makeListGuideToolsTool())
        tools.append(SetToolDescriptionTool())
        tools.append(ClearToolDescriptionTool())
        tools.append(AddGuideToolTool())
        tools.append(UpdateGuideToolTool())
        tools.append(DeleteGuideToolTool())

        // View-state tools — live-applied, no proposal.
        tools.append(makeOpenDownloadedTool(store: observationStore, viewer: .fits))
        tools.append(makeOpenDownloadedTool(store: observationStore, viewer: .cube))
        tools.append(makeChooseViewerTool())
        tools.append(makeSetSearchFocusTool())
        tools.append(makeNavigateToTool())
        let loadSavedSearch = makeLoadSavedSearchTool(savedStore: savedStore, recentStore: recentStore)
        tools.append(loadSavedSearch)
        tools.append(makeLoadRecentSearchTool(recentStore: recentStore))
        tools.append(makeRunSavedQueryTool(savedStore: savedStore))

        // Search form/results control — steer the live search form, data
        // train, ADQL editor, and results table (UI parity batch).
        // Windows wire names are primary; macOS legacy names stay as aliases.
        tools.append(makeGetSearchFormTool())
        let setSearchForm = makeSetSearchFormTool()
        tools.append(setSearchForm)
        tools.append(RunSearchTool(execute: {
            var args = SetSearchFormTool.Args()
            args.execute = true
            return await setSearchForm.apply(args)
        }))
        tools.append(makeResetSearchFormTool())
        tools.append(makeCancelSearchTool())
        tools.append(makeDescribeTapSchemaTool())
        tools.append(makeValidateADQLQueryTool())
        let getConstraints = makeGetDataTrainOptionsTool()
        tools.append(getConstraints)
        tools.append(AliasedToolBox(
            name: "get_data_train_options",
            description: "Alias of `get_search_constraints`.",
            inner: getConstraints))
        tools.append(SetSearchConstraintsTool(apply: { args in
            await setSearchForm.apply(args)
        }))
        tools.append(makeRefreshDataTrainTool())
        let setADQL = makeSetADQLEditorTool()
        tools.append(setADQL)
        tools.append(AliasedToolBox(
            name: "set_adql_editor",
            description: "Alias of `set_adql_query`.",
            inner: setADQL))
        tools.append(ExecuteADQLQueryTool(apply: { args in
            await setADQL.apply(args)
        }))
        tools.append(makeSelectSearchTabTool())
        tools.append(makeQuickSearchTool())
        tools.append(makeGetSearchResultsTool())
        let setResults = makeSetResultsViewTool()
        tools.append(setResults)
        tools.append(AliasedToolBox(
            name: "set_results_view",
            description: "Alias of `set_search_results_view`.",
            inner: setResults))
        tools.append(makeOpenObservationDetailTool())
        tools.append(makeShowSearchRowDetailTool())
        tools.append(makeShowObservationDetailTool())

        // Recent-searches writes — the side panel's rename/remove/clear.
        tools.append(RenameRecentSearchTool())
        tools.append(RemoveRecentSearchTool())
        tools.append(ClearRecentSearchesTool())

        // Viewer control — steer the app-owned FITS tab host + Cube model.
        tools.append(makeGetFITSViewTool())
        tools.append(makeSetFITSViewTool())
        tools.append(makeFITSGotoCoordinateTool())
        tools.append(makeProbeFITSPixelTool())
        tools.append(makeGetFITSImageTool())
        // Marks on FITS images
        tools.append(makeAnnotateFITSTool())
        tools.append(makeListFITSAnnotationsTool())
        tools.append(makeUpdateAnnotationTool())
        tools.append(makeSelectAnnotationTool())
        tools.append(makeRemoveAnnotationTool())
        tools.append(makeClearAnnotationsTool())
        tools.append(makeExportAnnotationsTool())
        tools.append(makeAnnotateCubeTool())
        tools.append(makeListCubeAnnotationsTool())
        tools.append(SaveObservationToResearchTool())
        tools.append(RemoveDownloadedFileTool())
        tools.append(makeShowResearchObservationTool())
        tools.append(makeGetCutoutOptionsTool())
        tools.append(makeDownloadCutoutTool())
        tools.append(makeShowCutoutEditorTool())
        tools.append(makeShowLaunchFormTool())
        tools.append(makeListFITSBookmarksTool())
        tools.append(makeGetCubeViewTool())
        tools.append(makeGetCubeImageTool())
        tools.append(makeSetCubeViewTool())
        tools.append(makeSetCubeCameraTool())
        tools.append(makeProbeCubeSpectrumTool())
        tools.append(makeListRecentCubesTool())
        tools.append(makeListRecentFITSTool())
        tools.append(makeShowCubeSpectrumTool())
        tools.append(makeGetCubeChannelProfileTool())
        tools.append(makeSetCubeTransferTool())
        tools.append(makeSwitchCubeTabTool())
        tools.append(makeListOpenTabsTool())
        let closeTab = makeCloseTabTool()
        tools.append(closeTab)
        tools.append(AliasedToolBox(
            name: "close_active_tab",
            description: "Alias of `close_tab`.",
            inner: closeTab))

        // FITS viewer parity — HDU selection, auto-cut, blink/compare,
        // tab-sync toggles, search-at-crosshair, figure export.
        tools.append(makeSelectHDUTool())
        tools.append(makeFITSAutoCutTool())
        tools.append(makeStartBlinkTool())
        tools.append(makeSetBlinkTool())
        tools.append(makeStopBlinkTool())
        tools.append(makeBlinkFITSTabsTool())
        tools.append(makeSwitchFITSTabTool())
        tools.append(makeSetTabSyncTool())
        tools.append(makeSearchAtCrosshairTool())
        tools.append(ExportFITSFigureTool())

        // Shell parity — the local file-browser panel and read-only
        // Settings views (Endpoints, AI Compute).
        tools.append(makeListLocalFolderTool())
        tools.append(makeOpenLocalFileTool())
        tools.append(makeRequestFolderAccessTool())
        tools.append(makeGetEndpointsTool())
        tools.append(makeGetComputeConfigTool())

        // Proposal-lifecycle tools — operate on the queue itself.
        tools.append(ListPendingProposalsTool())
        tools.append(GetProposalStateTool())
        tools.append(WithdrawProposalTool())
        let service = agentsService
        tools.append(StartBackgroundApplyTool(start: { id in await service.startBackgroundApply(id) }))
        tools.append(GetJobStatusTool(status: { id in await service.jobStatus(id) }))
        tools.append(ListEventsTool())

        registerWriteAppliers(savedQueryStore: savedStore,
                              noteStore: noteStore,
                              observationStore: observationStore,
                              vospace: vospace)

        return tools
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
        let hasResults = !searchModel.resultsModel.results.isEmpty
        return GetCurrentViewTool.Output(
            mode: Self.modeKey(currentMode),
            modeTitle: Self.modeTitle(currentMode),
            isAuthenticated: isAuthenticated,
            username: username,
            searchFocusRA: pendingSearchCoordinate?.ra,
            searchFocusDec: pendingSearchCoordinate?.dec,
            searchTab: searchModel.selectedTab.rawValue,
            searchResultsTotal: hasResults ? searchModel.resultsModel.totalRows : nil,
            searchResultsFiltered: hasResults ? searchModel.resultsModel.filteredCount : nil,
            // Real open tabs from the app-owned host (plus a pending open
            // that hasn't been consumed by the viewer yet).
            openFITSPaths: fitsTabHost.tabs.filter(\.isLoaded).compactMap { $0.fileURL?.path }
                + (pendingFITSURL.map { [$0.path] } ?? []),
            pendingViewerChoice: pendingViewerChoiceURL.map { url in
                GetCurrentViewTool.Output.PendingViewerChoice(
                    path: LocalFolderAccessStore.userFacingPath(for: url),
                    filename: url.lastPathComponent,
                    note: Self.viewerChoiceAgentNote(filename: url.lastPathComponent))
            },
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
        searchTab: nil,
        searchResultsTotal: nil,
        searchResultsFiltered: nil,
        openFITSPaths: [],
        pendingViewerChoice: nil,
        pendingProposalsCount: 0,
        agentsEnabled: false,
        autoApplyEnabled: false,
        followAgentActivityEnabled: false
    )

    private static func modeKey(_ mode: AppMode) -> String { mode.key }

    static func modeTitle(_ mode: AppMode) -> String { mode.title }

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

    private func makeGetEndpointsTool() -> GetEndpointsTool {
        let endpoints = self.endpoints
        return GetEndpointsTool(snapshot: {
            .init(loginBaseURL: endpoints.loginBaseURL,
                  skahaBaseURL: endpoints.skahaBaseURL,
                  acBaseURL: endpoints.acBaseURL,
                  storageBaseURL: endpoints.storageBaseURL,
                  registryBaseURL: endpoints.registryBaseURL,
                  archiveBaseURL: endpoints.archiveBaseURL,
                  externalBaseURL: endpoints.externalBaseURL)
        })
    }
}
