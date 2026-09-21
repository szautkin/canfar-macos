// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
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
        // Settings ▸ Compute.
        tools.append(RunCodeTool())
        tools.append(makeRunCodeOutputTool(service: vospace))
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
        tools.append(makeOpenFITSFileTool(store: observationStore))
        tools.append(makeOpenCubeTool(store: observationStore))
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

        // Recent-searches writes — the side panel's rename/remove/clear.
        tools.append(RenameRecentSearchTool())
        tools.append(RemoveRecentSearchTool())
        tools.append(ClearRecentSearchesTool())

        // Viewer control — steer the app-owned FITS tab host + Cube model.
        tools.append(makeGetFITSViewTool())
        tools.append(makeSetFITSViewTool())
        tools.append(makeFITSGotoCoordinateTool())
        tools.append(makeProbeFITSPixelTool())
        tools.append(makeListFITSBookmarksTool())
        tools.append(makeGetCubeViewTool())
        tools.append(makeSetCubeViewTool())
        tools.append(makeSetCubeCameraTool())
        tools.append(makeProbeCubeSpectrumTool())
        tools.append(makeListRecentCubesTool())
        tools.append(makeShowCubeSpectrumTool())
        tools.append(makeGetCubeChannelProfileTool())
        tools.append(makeSetCubeTransferTool())
        tools.append(makeSwitchCubeTabTool())
        tools.append(makeListOpenTabsTool())
        tools.append(makeCloseActiveTabTool())

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
        tools.append(ListEventsTool())

        registerWriteAppliers(savedQueryStore: savedStore,
                              noteStore: noteStore,
                              observationStore: observationStore,
                              vospace: vospace)

        return tools
    }

    /// Build the MCP guide resolver from the live `aiGuideService`. The closures
    /// weak-capture `self` and hop to the main actor to read `@Observable`
    /// state, so a user editing a description or adding a guide re-tunes a live
    /// agent session on its next `tools/list` (same idiom as the auto-apply
    /// hook). macOS-only — this file isn't part of the iOS target.
    func makeAIGuideResolver() -> AIGuideResolver {
        // Guide tools take no arguments: one shared empty-object schema.
        let emptySchema = AIToolDefinition.withStaticSchema(
            name: "_guide_schema", description: "_",
            schema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ).inputSchema

        return AIGuideResolver(
            adjustments: { [weak self] in
                guard let self else { return .none }
                let snapshot = await MainActor.run { self.aiGuideService.snapshot() }
                let guideTools = snapshot.guides.map { guide in
                    AIToolDefinition(name: guide.name, description: guide.description, inputSchema: emptySchema)
                }
                return AIGuideResolver.Adjustments(
                    descriptionOverrides: snapshot.overrides,
                    guideTools: guideTools
                )
            },
            guideBody: { [weak self] name in
                guard let self else { return nil }
                return await MainActor.run { self.aiGuideService.snapshot().guideBody(forName: name) }
            }
        )
    }

    /// Project the live registered tools into AI Guide inputs (name + built-in
    /// description + category) for the AI Guide screen. Reads the tools the
    /// router actually exposes, so the screen and the agent always agree.
    func aiGuideToolInputs() -> [AIGuideToolInput] {
        agentsService.tools.map { tool in
            AIGuideToolInput(
                name: tool.name,
                defaultDescription: tool.definition.description,
                category: AIGuideCatalog.categoryID(forTool: tool.name)
            )
        }
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
        return OpenFITSFileTool(openFITS: { [weak self] rawID in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let obs = await MainActor.run { store.observation(matching: rawID) }
            guard let obs else {
                throw ToolFailureReason.observationNotFound(id: rawID, localPath: nil)
            }
            let url = try Self.resolveAccessibleFileURL(for: obs).url
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

    /// Cube-viewer twin of `makeOpenFITSFileTool` — resolves the downloaded
    /// observation's URL and routes it into the Cube Viewer (its own mode).
    private func makeOpenCubeTool(store: ObservationStore) -> OpenCubeTool {
        let activity = agentsService.activityStore
        return OpenCubeTool(openCube: { [weak self] rawID in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let obs = await MainActor.run { store.observation(matching: rawID) }
            guard let obs else {
                throw ToolFailureReason.observationNotFound(id: rawID, localPath: nil)
            }
            let url = try Self.resolveAccessibleFileURL(for: obs).url
            let origin: OperationOrigin = .external(clientID: "open_cube")
            await MainActor.run {
                if self.currentMode != .cubeViewer {
                    self.navigateTo(.cubeViewer)
                }
                self.pendingCubeURL = url
                activity.append(.live(
                    kind: "open_cube",
                    summary: "Opened cube: \(obs.observationID) (\(obs.collection))",
                    origin: origin
                ))
            }
            return (observationID: obs.observationID, localPath: obs.localPath)
        })
    }

    private func makeChooseViewerTool() -> ChooseViewerTool {
        let activity = agentsService.activityStore
        return ChooseViewerTool(choose: { [weak self] viewer in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                guard let url = self.pendingViewerChoiceURL else {
                    throw ToolFailureReason.invalidArgument(
                        "No Open as… sheet is showing. Call get_current_view — pendingViewerChoice is set when a NAXIS≥3 file needs a 2D vs 3D pick.")
                }
                let path = LocalFolderAccessStore.userFacingPath(for: url)
                let name = url.lastPathComponent
                switch viewer {
                case "fits":
                    self.openPendingViewerChoiceAsFITS()
                    activity.append(.live(
                        kind: "choose_viewer",
                        summary: "Opened \(name) in FITS Viewer",
                        origin: .external(clientID: "choose_viewer")))
                    return ChooseViewerTool.Output(
                        applied: true, viewer: "fits", path: path,
                        note: "Opened in the 2D FITS Viewer.")
                case "cube":
                    self.openPendingViewerChoiceAsCube()
                    activity.append(.live(
                        kind: "choose_viewer",
                        summary: "Opened \(name) in Cube Viewer",
                        origin: .external(clientID: "choose_viewer")))
                    return ChooseViewerTool.Output(
                        applied: true, viewer: "cube", path: path,
                        note: "Opened in the 3D Cube Viewer.")
                case "dismiss":
                    self.pendingViewerChoiceURL = nil
                    activity.append(.live(
                        kind: "choose_viewer",
                        summary: "Dismissed Open as… for \(name)",
                        origin: .external(clientID: "choose_viewer")))
                    return ChooseViewerTool.Output(
                        applied: true, viewer: "dismiss", path: path,
                        note: "Closed the Open as… sheet without opening the file.")
                default:
                    throw ToolFailureReason.invalidArgument(
                        "viewer must be 'fits', 'cube', or 'dismiss'")
                }
            }
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

    private func makeListWorkflowsTool() -> ListWorkflowsTool {
        ListWorkflowsTool(list: { [weak self] in
            await MainActor.run {
                guard let self else { return [] }
                return self.workflowStore.listBuiltIn() + self.workflowStore.listLocal()
            }
        })
    }

    private func makeGetWorkflowTool() -> GetWorkflowTool {
        GetWorkflowTool(get: { [weak self] id in
            await MainActor.run { self?.workflowStore.get(id) }
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
                let outcome = await self.openAstronomyFITSAwaitingChoice(url: tempURL)
                if case .awaitingViewerChoice = outcome {
                    return AppState.viewerChoiceAgentNote(filename: tempURL.lastPathComponent)
                }
                return nil
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

    /// Appliers for the five AI Guide mutations. One shared applier shape;
    /// the closures do the MainActor `aiGuideService` calls plus the
    /// built-in-name shadow check for guide names.
    private func makeAIGuideAppliers(activity: AgentActivityStore) -> [any ProposalApplier] {
        // Guide (or override target) names are checked against the LIVE
        // registered tool table at apply time.
        let builtinNames: @MainActor () -> Set<String> = { [weak self] in
            guard let self else { return [] }
            return Set(self.aiGuideToolInputs().map(\.name))
        }
        return [
            AIGuideMutationApplier(kind: "set_tool_description", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(SetToolDescriptionTool.Payload.self, from: proposal.payload)
                try await MainActor.run {
                    guard builtinNames().contains(p.toolName) else {
                        throw ProposalApplyError.backendError("no tool named '\(p.toolName)'")
                    }
                    try self.aiGuideService.setOverride(toolName: p.toolName, description: p.description)
                }
            }, activity: activity),
            AIGuideMutationApplier(kind: "clear_tool_description", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(ClearToolDescriptionTool.Payload.self, from: proposal.payload)
                await MainActor.run { self.aiGuideService.clearOverride(toolName: p.toolName) }
            }, activity: activity),
            AIGuideMutationApplier(kind: "add_guide_tool", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(AddGuideToolTool.Payload.self, from: proposal.payload)
                try await MainActor.run {
                    guard !builtinNames().contains(p.name) else {
                        throw ProposalApplyError.backendError("'\(p.name)' would shadow a built-in tool")
                    }
                    _ = try self.aiGuideService.addGuide(
                        name: p.name, description: p.description, body: p.body)
                }
            }, activity: activity),
            AIGuideMutationApplier(kind: "update_guide_tool", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(UpdateGuideToolTool.Payload.self, from: proposal.payload)
                guard let id = UUID(uuidString: p.id) else {
                    throw ProposalApplyError.backendError("invalid id")
                }
                try await MainActor.run {
                    guard !builtinNames().contains(p.name) else {
                        throw ProposalApplyError.backendError("'\(p.name)' would shadow a built-in tool")
                    }
                    try self.aiGuideService.updateGuide(
                        id: id, name: p.name, description: p.description, body: p.body)
                }
            }, activity: activity),
            AIGuideMutationApplier(kind: "delete_guide_tool", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(DeleteGuideToolTool.Payload.self, from: proposal.payload)
                guard let id = UUID(uuidString: p.id) else {
                    throw ProposalApplyError.backendError("invalid id")
                }
                await MainActor.run { self.aiGuideService.deleteGuide(id: id) }
            }, activity: activity),
        ]
    }

    private func makeListGuideToolsTool() -> ListGuideToolsTool {
        ListGuideToolsTool(snapshot: { [weak self] in
            guard let self else { return [] }
            return await MainActor.run {
                self.aiGuideService.guides.map {
                    ListGuideToolsTool.Output.Entry(
                        id: $0.id.uuidString, name: $0.name,
                        description: $0.description,
                        hasBody: !($0.body ?? "").isEmpty)
                }
            }
        })
    }

    // MARK: - Parity-batch helpers (search export, research bundle)

    /// Export current in-app results (when `adql` is omitted) or a
    /// caller-supplied TAP query. Matches `get_search_results` for the
    /// omit-adql path so agents can dump what the user is looking at.
    private func runSearchExport(
        format: String, adql: String?, maxRecords: Int?
    ) async throws -> String {
        let custom = adql?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty {
            return try await Self.exportServerADQL(format: format, adql: custom, maxRecords: maxRecords)
        }
        let snapshot: (rows: [SearchResult], columns: SearchResultColumns, liveADQL: String) = await MainActor.run {
            let model = self.searchModel.resultsModel
            return (model.fullFilteredSortedResults, model.columns, model.adqlQuery)
        }
        guard !snapshot.rows.isEmpty else {
            throw ProposalApplyError.backendError(
                "No current search results to export — run a search or pass `adql`."
            )
        }
        let capped = maxRecords.map { Array(snapshot.rows.prefix($0)) } ?? snapshot.rows
        switch format {
        case "csv":
            let temp = try ResultExportService.exportClientSide(rows: capped, columns: snapshot.columns, format: .csv)
            return try Self.moveExportToDownloads(tempURL: temp, ext: "csv")
        case "tsv":
            let temp = try ResultExportService.exportClientSide(rows: capped, columns: snapshot.columns, format: .tsv)
            return try Self.moveExportToDownloads(tempURL: temp, ext: "tsv")
        case "votable":
            let live = snapshot.liveADQL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !live.isEmpty else {
                throw ProposalApplyError.backendError(
                    "VOTable export of the current table needs the live ADQL (none loaded). Pass `adql`, or export csv/tsv."
                )
            }
            return try await Self.exportServerADQL(format: format, adql: live, maxRecords: maxRecords ?? capped.count)
        default:
            throw ProposalApplyError.backendError("unsupported format '\(format)'")
        }
    }

    private nonisolated static func exportServerADQL(
        format: String, adql: String, maxRecords: Int?
    ) async throws -> String {
        let ext: String
        switch format {
        case "csv": ext = "csv"
        case "tsv": ext = "tsv"
        case "votable": ext = "xml"
        default: throw ProposalApplyError.backendError("unsupported format '\(format)'")
        }
        var components = URLComponents(string: "\(TAPConfig.baseURL)\(TAPConfig.syncPath)")
        components?.queryItems = [
            URLQueryItem(name: "LANG", value: "ADQL"),
            URLQueryItem(name: "FORMAT", value: format),
            URLQueryItem(name: "QUERY", value: adql),
            URLQueryItem(name: "MAXREC", value: String(maxRecords ?? TAPConfig.maxRecords)),
        ]
        guard let url = components?.url else {
            throw ProposalApplyError.backendError("could not build the TAP export URL")
        }
        let temp = try await ResultExportService.exportServerSide(
            url: url, ext: ext, session: ResultExportService.makeExportSession())
        return try moveExportToDownloads(tempURL: temp, ext: ext)
    }

    private nonisolated static func moveExportToDownloads(tempURL: URL, ext: String) throws -> String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dest = downloads.appendingPathComponent(
            "verbinal-results-\(formatter.string(from: Date())).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest.path
    }

    /// Headless twin of the Export dialog's happy path: Research module →
    /// timestamped bundle in ~/Downloads, optional zip-and-upload to
    /// VOSpace `Verbinal-Exports/`.
    private func runResearchBundleExport(
        includeFileCopies: Bool,
        uploadToVOSpace: Bool,
        vospace: VOSpaceBrowserService,
        observationStore: ObservationStore,
        noteStore: ObservationNoteStore
    ) async throws {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let exporter = ResearchExporter(observationStore: observationStore, noteStore: noteStore)
        let service = ExportService()
        let options = ExportOptions(includeFileCopies: includeFileCopies)
        guard let bundleURL = await service.exportAll(to: downloads, modules: [exporter], options: options) else {
            throw ProposalApplyError.backendError(service.lastError ?? "export failed")
        }
        if uploadToVOSpace {
            guard !username.isEmpty else {
                throw ProposalApplyError.backendError("Sign in to CADC before uploading to VOSpace")
            }
            _ = try await service.uploadBundleToVOSpace(
                bundleURL: bundleURL, vospace: vospace, username: username)
        }
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

    // MARK: - Sessions parity (events, logs, connect)

    private func makeGetSessionEventsTool() -> GetSessionEventsTool {
        let service = self.sessionService
        return GetSessionEventsTool(fetch: { id in
            try await service.getSessionEvents(id: id)
        })
    }

    private func makeGetSessionLogsTool() -> GetSessionLogsTool {
        let service = self.sessionService
        return GetSessionLogsTool(fetch: { id in
            try await service.getSessionLogs(id: id)
        })
    }

    private func makeOpenSessionTool() -> OpenSessionTool {
        let service = self.sessionService
        let activity = agentsService.activityStore
        return OpenSessionTool(open: { id in
            let sessions: [Session]
            do {
                sessions = try await service.getSessions()
            } catch {
                return .rejected("Could not list sessions: \(error.localizedDescription)")
            }
            guard let session = sessions.first(where: { $0.id == id }) else {
                return .rejected("No session with id '\(id)'")
            }
            guard session.isRunning else {
                return .rejected("Session '\(id)' is \(session.status), not Running")
            }
            guard let url = URL(string: session.connectUrl) else {
                return .rejected("Session '\(id)' has no valid connect URL")
            }
            return await MainActor.run {
                NSWorkspace.shared.open(url)
                activity.append(.live(
                    kind: "open_session",
                    summary: "Opened session '\(session.sessionName)' in the browser",
                    origin: .external(clientID: "open_session")))
                return .opened(url.absoluteString)
            }
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

    private func makeListProbeFailuresTool() -> ListProbeFailuresTool {
        ListProbeFailuresTool(snapshot: { [weak self] in
            guard let coordinator = await self?.imageDiscoveryCoordinator else { return [] }
            let iso = ISO8601DateFormatter()
            var failures: [ListProbeFailuresTool.Output.Failure] = []
            for id in await coordinator.knownImages() {
                if case .failure(let imageID, let category, let message, let attemptedAt, let jobID)
                    = await coordinator.outcome(for: id) {
                    failures.append(.init(
                        imageID: imageID,
                        category: category.rawValue,
                        message: message,
                        attemptedAtISO: iso.string(from: attemptedAt),
                        jobID: jobID))
                }
            }
            return failures
        })
    }

    private func makeGetProbeLogsTool() -> GetProbeLogsTool {
        GetProbeLogsTool(fetch: { [weak self] jobID in
            guard let coordinator = await self?.imageDiscoveryCoordinator else {
                throw ToolFailureReason.authRequired
            }
            // Logs and events are independent fetches; run them together.
            async let logs = coordinator.fetchLogs(jobID: jobID)
            async let events = coordinator.fetchEvents(jobID: jobID)
            return (logs: try await logs, events: try await events)
        })
    }

    private func makeGetImageManifestTool() -> GetImageManifestTool {
        GetImageManifestTool(lookup: { [weak self] image in
            guard let coordinator = await self?.imageDiscoveryCoordinator else { return nil }
            guard case .success(let manifest) = await coordinator.outcome(for: image) else {
                return nil
            }
            let iso = ISO8601DateFormatter()
            return GetImageManifestTool.Output(
                imageID: manifest.imageID,
                capturedAtISO: iso.string(from: manifest.capturedAt),
                contentHash: manifest.contentHash,
                osFamily: manifest.osFamily,
                osVersion: manifest.osVersion,
                kernel: manifest.kernel,
                dpkgCount: manifest.dpkgPackages.count,
                rpmCount: manifest.rpmPackages.count,
                apkCount: manifest.apkPackages.count,
                pythonCount: manifest.pythonPackages.count,
                rCount: manifest.rPackages.count,
                condaEnvNames: manifest.condaEnvs.map(\.name))
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
    /// and return the snapshot. Tries the security-scoped bookmark
    /// *before* `fileExists` on the stored path — a sandbox miss on the
    /// user-facing Downloads string is not "file gone" (2026-08-28 re-test).
    nonisolated private static func resolveFITS(id: String, store: ObservationStore) async throws -> ResolvedFITS? {
        let obs = await MainActor.run { store.observation(matching: id) }
        guard let obs else {
            throw ToolFailureReason.observationNotFound(id: id, localPath: nil)
        }
        let access = try resolveAccessibleFileURL(for: obs)
        defer {
            if access.didStart { access.url.stopAccessingSecurityScopedResource() }
        }
        do {
            let file = try FITSParser.parse(url: access.url)
            return ResolvedFITS(observationID: obs.observationID, file: file)
        } catch {
            throw ToolFailureReason.backendError("FITS parse: \(error.localizedDescription)")
        }
    }

    /// Bookmark first, then sandbox-mapped path candidates. Never require
    /// `DownloadedObservation.fileExists` before attempting the bookmark.
    nonisolated private static func resolveAccessibleFileURL(for obs: DownloadedObservation) throws -> (url: URL, didStart: Bool) {
        if let bookmark = obs.bookmarkData {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    bookmarkDataIsStale: &stale)
                let didStart = url.startAccessingSecurityScopedResource()
                if FileManager.default.fileExists(atPath: url.path) {
                    return (url, didStart)
                }
                if didStart { url.stopAccessingSecurityScopedResource() }
            } catch {
                // Stale bookmark — fall through to path candidates.
            }
        }
        if let url = obs.resolvedReadableURL {
            return (url, false)
        }
        throw ToolFailureReason.observationNotFound(id: obs.id.uuidString, localPath: obs.localPath)
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
        GetDownloadedObservationTool(lookup: { @MainActor raw in
            store.observation(matching: raw).map { Self.flatten($0) }
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
            openFITSPaths: fitsTabHost.tabs.compactMap { $0.fileURL?.path }
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

    private static func modeKey(_ mode: AppMode) -> String {
        switch mode {
        case .landing:    return "landing"
        case .search:     return "search"
        case .research:   return "research"
        case .portal:     return "portal"
        case .storage:    return "storage"
        case .fitsViewer: return "fitsViewer"
        case .cubeViewer: return "cubeViewer"
        case .aiGuide:    return "aiGuide"
        case .workflows:  return "workflows"
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
        case .cubeViewer: return "Cube Viewer"
        case .aiGuide:    return "AI Guide"
        case .workflows:  return "Workflows"
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
                morphologyType: r.morphologyType,
                note: r.objectType == nil ? nil : ResolveTargetTool.objectTypeCaveat
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

    // MARK: - Platform & quota reads

    private func makeGetPlatformLoadTool() -> GetPlatformLoadTool {
        let service = platformService
        return GetPlatformLoadTool(fetch: {
            let stats = try await service.getStats()
            return GetPlatformLoadTool.Output(
                instances: stats.instances.map {
                    .init(session: $0.session, desktopApp: $0.desktopApp,
                          headless: $0.headless, total: $0.total)
                },
                cores: stats.cores.map {
                    .init(requested: $0.requestedCPUCores, available: $0.cpuCoresAvailable)
                },
                ram: stats.ram.map {
                    .init(requestedGB: $0.requestedRAM.map { PlatformLoadModel.parseRamGB($0) },
                          availableGB: $0.ramAvailable.map { PlatformLoadModel.parseRamGB($0) })
                }
            )
        })
    }

    private func makeGetStorageQuotaTool() -> GetStorageQuotaTool {
        let service = storageService
        return GetStorageQuotaTool(fetch: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let user = await self.username
            guard !user.isEmpty else { throw ToolFailureReason.authRequired }
            let quota = try await service.getQuota(username: user)
            return GetStorageQuotaTool.Output(
                usedBytes: quota.usedBytes, quotaBytes: quota.quotaBytes,
                usedGB: quota.usedGB, quotaGB: quota.quotaGB,
                usagePercent: quota.usagePercent
            )
        })
    }

    // MARK: - Search form loading

    private func makeLoadSavedSearchTool(
        savedStore: SavedQueryStore, recentStore: RecentSearchStore
    ) -> LoadSavedSearchTool {
        let activity = agentsService.activityStore
        return LoadSavedSearchTool(apply: { [weak self] savedID, recentID in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                if let savedID {
                    guard let uuid = UUID(uuidString: savedID),
                          let query = savedStore.queries.first(where: { $0.id == uuid }) else {
                        return "Saved query not found: \(savedID)"
                    }
                    self.pendingSearchLoad = AppState.PendingSearchLoad(kind: .adql(query.adql))
                    self.navigateTo(.search)
                    activity.append(.live(
                        kind: "load_saved_search",
                        summary: "Loaded saved query '\(query.name)' into the ADQL editor",
                        origin: .external(clientID: "load_saved_search")))
                    return nil
                }
                if let recentID {
                    guard let uuid = UUID(uuidString: recentID),
                          let recent = recentStore.searches.first(where: { $0.id == uuid }) else {
                        return "Recent search not found: \(recentID)"
                    }
                    self.pendingSearchLoad = AppState.PendingSearchLoad(kind: .snapshot(recent.formSnapshot))
                    self.navigateTo(.search)
                    activity.append(.live(
                        kind: "load_saved_search",
                        summary: "Loaded recent search '\(recent.name)' into the form",
                        origin: .external(clientID: "load_saved_search")))
                    return nil
                }
                return "Pass savedQueryID or recentSearchID"
            }
        })
    }

    private func makeLoadRecentSearchTool(recentStore: RecentSearchStore) -> LoadRecentSearchTool {
        let activity = agentsService.activityStore
        return LoadRecentSearchTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let recent: RecentSearch?
                if let id = args.recentSearchID {
                    recent = UUID(uuidString: id).flatMap { uuid in
                        recentStore.searches.first(where: { $0.id == uuid })
                    }
                    if recent == nil { return "Recent search not found: \(id)" }
                } else if let index = args.index {
                    guard recentStore.searches.indices.contains(index) else {
                        return "Recent search index \(index) out of range (count=\(recentStore.searches.count))"
                    }
                    recent = recentStore.searches[index]
                } else {
                    return "Pass index or recentSearchID"
                }
                guard let recent else { return "Recent search not found" }
                self.pendingSearchLoad = AppState.PendingSearchLoad(kind: .snapshot(recent.formSnapshot))
                self.navigateTo(.search)
                activity.append(.live(
                    kind: "load_recent_search",
                    summary: "Loaded recent search '\(recent.name)' into the form",
                    origin: .external(clientID: "load_recent_search")))
                return nil
            }
        })
    }

    private func makeRunSavedQueryTool(savedStore: SavedQueryStore) -> RunSavedQueryTool {
        let activity = agentsService.activityStore
        return RunSavedQueryTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let query: SavedQuery?
                if let id = args.savedQueryID {
                    query = UUID(uuidString: id).flatMap { uuid in
                        savedStore.queries.first(where: { $0.id == uuid })
                    }
                    if query == nil { return "Saved query not found: \(id)" }
                } else if let name = args.name {
                    query = savedStore.queries.first(where: { $0.name == name })
                    if query == nil { return "Saved query not found: \(name)" }
                } else {
                    return "Pass name or savedQueryID"
                }
                guard let query else { return "Saved query not found" }
                self.navigateTo(.search)
                self.searchModel.selectedTab = .adql
                self.searchModel.resultsModel.adqlQuery = query.adql
                activity.append(.live(
                    kind: "run_saved_query",
                    summary: "Ran saved query '\(query.name)'",
                    origin: .external(clientID: "run_saved_query")))
                Task { await self.searchModel.executeRawQuery(query.adql) }
                return nil
            }
        })
    }

    // MARK: - Shell parity (local files, settings reads)

    private func makeListLocalFolderTool() -> ListLocalFolderTool {
        ListLocalFolderTool(list: { [weak self] args in
            let requested = args.path ?? LocalFolderAccessStore.userFacingDownloadsRoot.path
            let candidates = LocalFolderAccessStore.candidateURLs(for: requested, isDirectory: true)
            let displayPath = LocalFolderAccessStore.userFacingPath(
                for: candidates.first ?? URL(fileURLWithPath: LocalFolderAccessStore.expandedPath(requested), isDirectory: true))
            var allowed: [URL] = []
            if let self {
                for url in candidates {
                    if await self.localFolderAccess.hasAccess(to: url) {
                        allowed.append(url)
                    }
                }
                if allowed.isEmpty {
                    throw ToolFailureReason.notReadable(
                        "'\(displayPath)' is outside the app sandbox. Only ~/Downloads and folders the user has granted are readable. Ask the user to grant this folder in Storage, then retry — `request_folder_access` cannot show a picker from an MCP client.")
                }
            } else {
                allowed = candidates
            }
            var listedURL: URL?
            var byName: [String: URL] = [:]
            var lastListError: Error?
            var sawMissing = true
            for url in allowed {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                sawMissing = false
                guard isDir.boolValue else {
                    throw ToolFailureReason.invalidArgument("'\(displayPath)' is a file, not a folder")
                }
                do {
                    let items = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: [.skipsHiddenFiles])
                    if listedURL == nil { listedURL = url }
                    for item in items where byName[item.lastPathComponent] == nil {
                        byName[item.lastPathComponent] = item
                    }
                } catch {
                    lastListError = error
                }
            }
            guard listedURL != nil || !byName.isEmpty else {
                if let lastListError {
                    throw ToolFailureReason.notReadable(
                        "cannot read '\(displayPath)': \(lastListError.localizedDescription)")
                }
                if sawMissing {
                    throw ToolFailureReason.unknownTarget("no folder at '\(displayPath)'")
                }
                throw ToolFailureReason.notReadable("cannot read '\(displayPath)'")
            }
            let contents = Array(byName.values)
            let sorted = contents.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            var entries: [ListLocalFolderTool.Output.Entry] = []
            var truncated = false
            for item in sorted {
                if entries.count >= 500 { truncated = true; break }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values?.isDirectory ?? false
                let fits = !isDirectory && FileHelper.isFITS(item.pathExtension)
                if args.supportedOnly == true && !isDirectory && !fits { continue }
                entries.append(.init(
                    name: item.lastPathComponent,
                    isDirectory: isDirectory,
                    sizeBytes: (values?.fileSize).map(Int64.init),
                    isFITS: fits))
            }
            return .init(
                path: listedURL.map { LocalFolderAccessStore.userFacingPath(for: $0) } ?? displayPath,
                entries: entries,
                truncated: truncated)
        })
    }

    private func makeOpenLocalFileTool() -> OpenLocalFileTool {
        let activity = agentsService.activityStore
        return OpenLocalFileTool(open: { [weak self] path, viewer in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            let url = LocalFolderAccessStore.readableURL(for: path, directory: false)
                ?? LocalFolderAccessStore.resolveSandboxPath(
                    URL(fileURLWithPath: LocalFolderAccessStore.expandedPath(path)))
            let displayPath = LocalFolderAccessStore.userFacingPath(for: url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolFailureReason.unknownTarget("No file at '\(displayPath)'")
            }
            guard FileHelper.isFITS(url.pathExtension) else {
                throw ToolFailureReason.invalidArgument("'\(url.lastPathComponent)' is not a FITS file")
            }
            if await !self.localFolderAccess.hasAccess(to: url) {
                throw ToolFailureReason.notReadable(
                    "'\(displayPath)' is outside the app sandbox — ask the user to grant its folder in Storage, or move it to ~/Downloads.")
            }
            let choice = viewer.flatMap { AppState.AstronomyViewerChoice(rawValue: $0) }
            let outcome = await self.openAstronomyFITSAwaitingChoice(url: url, viewer: choice)
            let name = url.lastPathComponent
            switch outcome {
            case .openedFITS:
                await MainActor.run {
                    activity.append(.live(
                        kind: "open_local_file",
                        summary: "Opened \(name) in FITS Viewer",
                        origin: .external(clientID: "open_local_file")))
                }
                return .init(applied: true, path: displayPath, viewer: "fits",
                             pendingViewerChoice: false, note: nil)
            case .openedCube:
                await MainActor.run {
                    activity.append(.live(
                        kind: "open_local_file",
                        summary: "Opened \(name) in Cube Viewer",
                        origin: .external(clientID: "open_local_file")))
                }
                return .init(applied: true, path: displayPath, viewer: "cube",
                             pendingViewerChoice: false, note: nil)
            case .awaitingViewerChoice:
                await MainActor.run {
                    activity.append(.live(
                        kind: "open_local_file",
                        summary: "Asked how to open \(name)",
                        origin: .external(clientID: "open_local_file")))
                }
                return .init(
                    applied: true, path: displayPath, viewer: nil,
                    pendingViewerChoice: true,
                    note: AppState.viewerChoiceAgentNote(filename: name))
            }
        })
    }

    private func makeRequestFolderAccessTool() -> RequestFolderAccessTool {
        let activity = agentsService.activityStore
        return RequestFolderAccessTool(request: { [weak self] startingPath in
            guard let self else { return .cancelled }
            return await MainActor.run {
                let start = startingPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                guard let granted = try? self.localFolderAccess.grantAccess(startingAt: start) else {
                    return .cancelled
                }
                activity.append(.live(
                    kind: "request_folder_access",
                    summary: "Granted folder access: \(granted.path)",
                    origin: .external(clientID: "request_folder_access")))
                return .granted(granted.path)
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

    private func makeGetComputeConfigTool() -> GetComputeConfigTool {
        GetComputeConfigTool(snapshot: { [weak self] in
            guard let self else {
                return .init(isEnabled: false, image: "", cores: 0, ramGB: 0,
                             registryHost: "", registryUsername: "", hasRegistrySecret: false)
            }
            return await MainActor.run {
                let settings = self.aiComputeSettings.settings
                return GetComputeConfigTool.Output(
                    isEnabled: settings.isEnabled,
                    image: settings.image,
                    cores: settings.cores,
                    ramGB: settings.ram,
                    registryHost: settings.registryHost,
                    registryUsername: settings.username,
                    hasRegistrySecret: settings.hasSecret)
            }
        })
    }

    // MARK: - Search form/results control

    /// Map the app's `IntentValue` / `DatePresetValue` to the agent-facing
    /// keys (the raw values are TAP wire strings like "" that read poorly
    /// in a tool result).
    private nonisolated static func intentKey(_ intent: IntentValue) -> String {
        switch intent {
        case .any: return "any"
        case .science: return "science"
        case .calibration: return "calibration"
        }
    }

    private nonisolated static func datePresetKey(_ preset: DatePresetValue) -> String {
        switch preset {
        case .none: return "none"
        case .past24Hours: return "past24Hours"
        case .pastWeek: return "pastWeek"
        case .pastMonth: return "pastMonth"
        }
    }

    private nonisolated static func columnKindKey(_ kind: ColumnKind) -> String {
        switch kind {
        case .text: return "text"
        case .integer: return "integer"
        case .number: return "number"
        case .mjdDate: return "mjdDate"
        case .isoDate: return "isoDate"
        case .boolean: return "boolean"
        }
    }

    /// Resolver coordinates in the exact shape `ADQLBuilder.buildQuery`
    /// and `executeSearch` consume.
    @MainActor
    private static func resolverCoords(of model: SearchFormModel) -> (ra: String, dec: String)? {
        guard let result = model.resolverResult, !result.coordsRA.isEmpty else { return nil }
        return (ra: result.coordsRA, dec: result.coordsDec)
    }

    private nonisolated static let emptySearchForm = GetSearchFormTool.Output(
        observationID: "", piName: "", proposalID: "", proposalTitle: "",
        proposalKeywords: "", dataRelease: "", publicOnly: false, intent: "any",
        target: "", resolver: "all", pixelScale: "",
        resolverStatus: "idle", resolvedRA: nil, resolvedDec: nil,
        observationDate: "", datePreset: "none", integrationTime: "", timeSpan: "",
        spectralCoverage: "", spectralSampling: "", resolvingPower: "",
        bandpassWidth: "", restFrameEnergy: "",
        bands: [], collections: [], instruments: [], filters: [],
        calLevels: [], dataTypes: [], obsTypes: [],
        selectedTab: "search", isSearching: false, searchError: nil,
        generatedADQL: "")

    private func makeGetSearchFormTool() -> GetSearchFormTool {
        GetSearchFormTool(snapshot: { [weak self] in
            guard let self else { return Self.emptySearchForm }
            return await MainActor.run {
                let model = self.searchModel
                let state = model.formState
                var resolvedRA: String?
                var resolvedDec: String?
                let statusKey: String
                switch model.resolverStatus {
                case .idle: statusKey = "idle"
                case .resolving: statusKey = "resolving"
                case .resolved(let ra, let dec):
                    statusKey = "resolved"
                    resolvedRA = ra
                    resolvedDec = dec
                case .failed(let message): statusKey = "failed: \(message)"
                }
                return GetSearchFormTool.Output(
                    observationID: state.observationID,
                    piName: state.piName,
                    proposalID: state.proposalID,
                    proposalTitle: state.proposalTitle,
                    proposalKeywords: state.proposalKeywords,
                    dataRelease: state.dataRelease,
                    publicOnly: state.publicOnly,
                    intent: Self.intentKey(state.intent),
                    target: state.target,
                    resolver: state.resolver.rawValue.lowercased(),
                    pixelScale: state.pixelScale,
                    resolverStatus: statusKey,
                    resolvedRA: resolvedRA,
                    resolvedDec: resolvedDec,
                    observationDate: state.observationDate,
                    datePreset: Self.datePresetKey(state.datePreset),
                    integrationTime: state.integrationTime,
                    timeSpan: state.timeSpan,
                    spectralCoverage: state.spectralCoverage,
                    spectralSampling: state.spectralSampling,
                    resolvingPower: state.resolvingPower,
                    bandpassWidth: state.bandpassWidth,
                    restFrameEnergy: state.restFrameEnergy,
                    bands: state.selectedBands,
                    collections: state.selectedCollections,
                    instruments: state.selectedInstruments,
                    filters: state.selectedFilters,
                    calLevels: state.selectedCalLevels,
                    dataTypes: state.selectedDataTypes,
                    obsTypes: state.selectedObsTypes,
                    selectedTab: model.selectedTab.rawValue,
                    isSearching: model.isSearching,
                    searchError: model.searchError,
                    generatedADQL: ADQLBuilder.buildQuery(
                        formState: state,
                        resolverCoords: Self.resolverCoords(of: model)))
            }
        })
    }

    private func makeSetSearchFormTool() -> SetSearchFormTool {
        let activity = agentsService.activityStore
        return SetSearchFormTool(apply: { [weak self] args in
            guard let self else { return .init(error: "App state unavailable") }

            // Map enum-ish strings up front so bad values reject cleanly
            // before any form mutation.
            var intent: IntentValue?
            if let raw = args.intent {
                switch raw {
                case "any": intent = .any
                case "science": intent = .science
                case "calibration": intent = .calibration
                default: return .init(error: "Unknown intent '\(raw)'")
                }
            }
            var resolver: ResolverValue?
            if let raw = args.resolver {
                guard let value = ResolverValue(rawValue: raw.uppercased()) else {
                    return .init(error: "Unknown resolver '\(raw)'")
                }
                resolver = value
            }
            var datePreset: DatePresetValue?
            if let raw = args.datePreset {
                switch raw {
                case "none": datePreset = DatePresetValue.none
                case "past24Hours": datePreset = .past24Hours
                case "pastWeek": datePreset = .pastWeek
                case "pastMonth": datePreset = .pastMonth
                default: return .init(error: "Unknown datePreset '\(raw)'")
                }
            }

            let model = await self.searchModel
            let targetTouched: Bool = await MainActor.run {
                let state = model.formState
                if let v = args.observationID { state.observationID = v }
                if let v = args.piName { state.piName = v }
                if let v = args.proposalID { state.proposalID = v }
                if let v = args.proposalTitle { state.proposalTitle = v }
                if let v = args.proposalKeywords { state.proposalKeywords = v }
                if let v = args.dataRelease { state.dataRelease = v }
                if let v = args.publicOnly { state.publicOnly = v }
                if let v = intent { state.intent = v }
                if let v = args.target { state.target = v }
                if let v = resolver { state.resolver = v }
                if let v = args.pixelScale { state.pixelScale = v }
                if let v = args.observationDate { state.observationDate = v }
                if let v = datePreset { state.datePreset = v }
                if let v = args.integrationTime { state.integrationTime = v }
                if let v = args.timeSpan { state.timeSpan = v }
                if let v = args.spectralCoverage { state.spectralCoverage = v }
                if let v = args.spectralSampling { state.spectralSampling = v }
                if let v = args.resolvingPower { state.resolvingPower = v }
                if let v = args.bandpassWidth { state.bandpassWidth = v }
                if let v = args.restFrameEnergy { state.restFrameEnergy = v }

                // Data-train cascade: apply the provided columns, then
                // clear every column downstream of the highest provided
                // one that wasn't itself provided — the UI's rule that
                // an upstream change invalidates downstream selections.
                let train: [(Int, [String]?)] = [
                    (0, args.bands), (1, args.collections), (2, args.instruments),
                    (3, args.filters), (4, args.calLevels), (5, args.dataTypes),
                    (6, args.obsTypes),
                ]
                func setTrain(_ index: Int, _ values: [String]) {
                    switch index {
                    case 0: state.selectedBands = values
                    case 1: state.selectedCollections = values
                    case 2: state.selectedInstruments = values
                    case 3: state.selectedFilters = values
                    case 4: state.selectedCalLevels = values
                    case 5: state.selectedDataTypes = values
                    default: state.selectedObsTypes = values
                    }
                }
                if let lowest = train.compactMap({ $0.1 != nil ? $0.0 : nil }).min() {
                    for (index, values) in train {
                        if let values {
                            setTrain(index, values)
                        } else if index > lowest {
                            setTrain(index, [])
                        }
                    }
                }
                return args.target != nil || args.resolver != nil
            }

            var outcome = SetSearchFormTool.Outcome()
            if args.execute == true {
                if targetTouched {
                    // The UI debounces resolution behind typing; an
                    // immediate execute must wait for coordinates the
                    // same way a user pausing after typing would.
                    await model.resolveTargetNow()
                }
                // Stamp the auto-saved recent search with agent provenance
                // (live op — no proposal — so a synthetic attribution).
                await MainActor.run {
                    model.nextSearchAttribution = .forLiveTool(
                        label: "set_search_form", summary: "Ran a search from the form")
                }
                await model.executeSearch()
                outcome.executed = true
                let (count, error) = await MainActor.run {
                    (model.resultsModel.totalRows, model.searchError)
                }
                outcome.resultCount = count
                outcome.searchError = error
            } else if targetTouched {
                // Kick the UI's normal debounced resolution so the form
                // shows the resolver status the user expects to see.
                await MainActor.run { model.targetChanged() }
            }
            await MainActor.run {
                activity.append(.live(
                    kind: "set_search_form",
                    summary: args.execute == true
                        ? "Filled the search form and ran the search"
                        : "Filled the search form",
                    origin: .external(clientID: "set_search_form")))
            }
            return outcome
        })
    }

    private func makeResetSearchFormTool() -> ResetSearchFormTool {
        let activity = agentsService.activityStore
        return ResetSearchFormTool(reset: { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.searchModel.resetForm()
                activity.append(.live(
                    kind: "reset_search_form",
                    summary: "Reset the search form",
                    origin: .external(clientID: "reset_search_form")))
            }
        })
    }

    private func makeGetDataTrainOptionsTool() -> GetDataTrainOptionsTool {
        GetDataTrainOptionsTool(snapshot: { [weak self] in
            guard let self else {
                return .init(columns: [], lastRefreshedISO: nil,
                             isRefreshing: false, error: "App state unavailable")
            }
            let model = await self.searchModel
            // Idempotent: joins any in-flight load, serves cache instantly.
            await model.dataTrainModel.loadData()
            return await MainActor.run {
                let dataTrain = model.dataTrainModel
                let state = model.formState
                let meta: [(id: String, title: String)] = [
                    ("band", "Band"), ("collection", "Collection"),
                    ("instrument", "Instrument"), ("filter", "Filter"),
                    ("calLevel", "Cal. Level"), ("dataType", "Data Type"),
                    ("obsType", "Obs. Type"),
                ]
                let selections = [
                    state.selectedBands, state.selectedCollections,
                    state.selectedInstruments, state.selectedFilters,
                    state.selectedCalLevels, state.selectedDataTypes,
                    state.selectedObsTypes,
                ]
                let cap = 500
                let columns = meta.enumerated().map { index, entry in
                    let options = dataTrain.filteredOptions(for: index, formState: state)
                    return GetDataTrainOptionsTool.Output.Column(
                        index: index, id: entry.id, title: entry.title,
                        options: Array(options.prefix(cap)),
                        selected: selections[index],
                        truncated: options.count > cap)
                }
                return GetDataTrainOptionsTool.Output(
                    columns: columns,
                    lastRefreshedISO: dataTrain.lastRefreshed.map {
                        ISO8601DateFormatter().string(from: $0)
                    },
                    isRefreshing: dataTrain.isRefreshing,
                    error: dataTrain.hasError ? dataTrain.errorMessage : nil)
            }
        })
    }

    private func makeRefreshDataTrainTool() -> RefreshDataTrainTool {
        let activity = agentsService.activityStore
        return RefreshDataTrainTool(refresh: { [weak self] in
            guard let self else {
                return .init(error: "App state unavailable", lastRefreshedISO: nil)
            }
            let model = await self.searchModel
            await model.dataTrainModel.refreshData()
            return await MainActor.run {
                let dataTrain = model.dataTrainModel
                if dataTrain.hasError {
                    return RefreshDataTrainTool.Refreshed(
                        error: dataTrain.errorMessage, lastRefreshedISO: nil)
                }
                activity.append(.live(
                    kind: "refresh_data_train",
                    summary: "Refreshed the data-train facets from CADC",
                    origin: .external(clientID: "refresh_data_train")))
                return RefreshDataTrainTool.Refreshed(
                    error: nil,
                    lastRefreshedISO: dataTrain.lastRefreshed.map {
                        ISO8601DateFormatter().string(from: $0)
                    })
            }
        })
    }

    private func makeSetADQLEditorTool() -> SetADQLEditorTool {
        let activity = agentsService.activityStore
        return SetADQLEditorTool(apply: { [weak self] args in
            guard let self else { return .init(error: "App state unavailable") }
            let model = await self.searchModel
            let adql: String = await MainActor.run {
                if let text = args.adql {
                    model.resultsModel.adqlQuery = text
                } else if args.generateFromForm == true {
                    model.resultsModel.adqlQuery = ADQLBuilder.buildQuery(
                        formState: model.formState,
                        resolverCoords: Self.resolverCoords(of: model))
                }
                model.selectedTab = .adql
                return model.resultsModel.adqlQuery
            }
            var outcome = SetADQLEditorTool.Outcome(adql: adql)
            if args.execute == true {
                guard !adql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .init(error: "The ADQL editor is empty — pass `adql` or `generateFromForm`")
                }
                await model.executeRawQuery(adql)
                outcome.executed = true
                let (count, error) = await MainActor.run {
                    (model.resultsModel.totalRows, model.searchError)
                }
                outcome.resultCount = count
                outcome.searchError = error
            }
            await MainActor.run {
                activity.append(.live(
                    kind: "set_adql_editor",
                    summary: args.execute == true
                        ? "Set the ADQL editor and ran the query"
                        : "Set the ADQL editor",
                    origin: .external(clientID: "set_adql_editor")))
            }
            return outcome
        })
    }

    private func makeSelectSearchTabTool() -> SelectSearchTabTool {
        let activity = agentsService.activityStore
        return SelectSearchTabTool(select: { [weak self] raw in
            guard let self else { return "App state unavailable" }
            guard let tab = SearchFormModel.SearchTab(rawValue: raw) else {
                return "Unknown tab '\(raw)' — use search, results, or adql"
            }
            return await MainActor.run {
                self.searchModel.selectedTab = tab
                if self.currentMode != .search {
                    self.navigateTo(.search)
                }
                activity.append(.live(
                    kind: "select_search_tab",
                    summary: "Switched Search to the \(raw) tab",
                    origin: .external(clientID: "select_search_tab")))
                return nil
            }
        })
    }

    private func makeQuickSearchTool() -> QuickSearchTool {
        let activity = agentsService.activityStore
        return QuickSearchTool(run: { [weak self] columnID, value in
            guard let self else { return .init(error: "App state unavailable") }
            let quickSearchable = await MainActor.run {
                SearchFormModel.quickSearchableColumnIDs.contains(columnID)
            }
            guard quickSearchable else {
                return .init(error: "Column '\(columnID)' is not quick-searchable")
            }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return .init(error: "value is empty") }
            let model = await self.searchModel
            await MainActor.run {
                model.nextSearchAttribution = .forLiveTool(
                    label: "quick_search",
                    summary: "Quick-searched \(columnID) = '\(trimmed)'")
            }
            await model.quickSearch(columnID: columnID, rawValue: trimmed)
            return await MainActor.run {
                activity.append(.live(
                    kind: "quick_search",
                    summary: "Quick-searched \(columnID) = '\(trimmed)'",
                    origin: .external(clientID: "quick_search")))
                return QuickSearchTool.Outcome(
                    error: nil,
                    resultCount: model.resultsModel.totalRows,
                    searchError: model.searchError)
            }
        })
    }

    private nonisolated static let emptySearchResults = GetSearchResultsTool.Output(
        hasResults: false, adqlQuery: "", totalRows: 0, filteredCount: 0,
        maxRecordReached: false, currentPage: 0, totalPages: 1, rowsPerPage: 100,
        sortColumnID: nil, sortAscending: true, activeFilters: [:], columns: [],
        returnedPage: nil, rowIDs: [], rows: [], rowsTruncated: false)

    private func makeGetSearchResultsTool() -> GetSearchResultsTool {
        GetSearchResultsTool(snapshot: { [weak self] args in
            guard let self else { return Self.emptySearchResults }
            return await MainActor.run {
                let resultsModel = self.searchModel.resultsModel
                guard !resultsModel.results.isEmpty else { return Self.emptySearchResults }

                let includeAll = args.allColumns == true
                let cols = resultsModel.columns.list.filter { includeAll || $0.visible }
                let columns = cols.map {
                    GetSearchResultsTool.Output.Column(
                        id: $0.id, label: $0.label,
                        kind: Self.columnKindKey($0.kind),
                        visible: $0.visible,
                        selectedUnit: resultsModel.selectedUnit(for: $0.id))
                }

                var rows: [[String]] = []
                var rowIDs: [String] = []
                var returnedPage: Int?
                var truncated = false
                if args.includeRows ?? true {
                    let full = resultsModel.fullFilteredSortedResults
                    let perPage = resultsModel.rowsPerPage
                    let slice: ArraySlice<SearchResult>
                    if perPage <= 0 {
                        returnedPage = 0
                        slice = full[...]
                    } else {
                        let page = args.page ?? resultsModel.currentPage
                        returnedPage = page
                        let start = page * perPage
                        slice = start < full.count
                            ? full[start..<min(start + perPage, full.count)]
                            : full[0..<0]
                    }
                    let cap = min(max(args.maxRows ?? 200, 1), 1000)
                    truncated = slice.count > cap
                    let limited = slice.prefix(cap)
                    rowIDs = limited.map(\.id)
                    rows = limited.map { row in
                        cols.map { col in
                            row.rawValues.indices.contains(col.index)
                                ? row.rawValues[col.index] : ""
                        }
                    }
                }

                return GetSearchResultsTool.Output(
                    hasResults: true,
                    adqlQuery: resultsModel.adqlQuery,
                    totalRows: resultsModel.totalRows,
                    filteredCount: resultsModel.filteredCount,
                    maxRecordReached: resultsModel.maxRecordReached,
                    currentPage: resultsModel.currentPage,
                    totalPages: resultsModel.totalPages,
                    rowsPerPage: resultsModel.rowsPerPage,
                    sortColumnID: resultsModel.sortColumnID,
                    sortAscending: resultsModel.sortAscending,
                    activeFilters: resultsModel.columnFilters,
                    columns: columns,
                    returnedPage: returnedPage,
                    rowIDs: rowIDs,
                    rows: rows,
                    rowsTruncated: truncated)
            }
        })
    }

    private func makeSetResultsViewTool() -> SetResultsViewTool {
        let activity = agentsService.activityStore
        return SetResultsViewTool(apply: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let resultsModel = self.searchModel.resultsModel
                guard !resultsModel.results.isEmpty else {
                    return .rejected("No search results are loaded")
                }

                // Validate every reference before mutating anything, so a
                // rejected call leaves the table exactly as the user had it.
                if let id = args.sortColumnID, resultsModel.columns.column(id: id) == nil {
                    return .rejected("Unknown column '\(id)'")
                }
                if let visible = args.visibleColumns {
                    guard !visible.isEmpty else {
                        return .rejected("visibleColumns must not be empty")
                    }
                    for id in visible where resultsModel.columns.column(id: id) == nil {
                        return .rejected("Unknown column '\(id)'")
                    }
                }
                if let filters = args.filters {
                    for id in filters.keys where resultsModel.columns.column(id: id) == nil {
                        return .rejected("Unknown column '\(id)'")
                    }
                }
                if let units = args.columnUnits {
                    for (id, unit) in units {
                        guard let available = CellFormatterRegistry.availableUnits(for: id) else {
                            return .rejected("Column '\(id)' has no unit choices")
                        }
                        guard available.contains(where: { $0.unitID == unit }) else {
                            return .rejected("Unknown unit '\(unit)' for column '\(id)'")
                        }
                    }
                }
                if let perPage = args.rowsPerPage,
                   !SearchResultsModel.rowsPerPageOptions.contains(perPage) {
                    return .rejected("rowsPerPage must be one of 50, 100, 500, or 0 (all)")
                }

                if args.clearSort == true { resultsModel.sortColumnID = nil }
                if let id = args.sortColumnID {
                    resultsModel.sortAscending = args.sortAscending ?? true
                    resultsModel.sortColumnID = id
                } else if let ascending = args.sortAscending {
                    resultsModel.sortAscending = ascending
                }
                if args.clearFilters == true { resultsModel.columnFilters = [:] }
                if let filters = args.filters {
                    for (id, text) in filters { resultsModel.setFilter(id, text: text) }
                }
                if args.resetColumnVisibility == true { resultsModel.resetColumnVisibility() }
                if let visible = args.visibleColumns {
                    let visibleSet = Set(visible)
                    for col in resultsModel.columns.list {
                        resultsModel.columns.setVisibility(
                            id: col.id, visible: visibleSet.contains(col.id))
                    }
                    resultsModel.columns.persistVisibility()
                }
                if let units = args.columnUnits {
                    for (id, unit) in units {
                        resultsModel.setUnit(columnID: id, unitID: unit)
                    }
                }
                if let perPage = args.rowsPerPage { resultsModel.rowsPerPage = perPage }
                if let page = args.page {
                    resultsModel.currentPage = max(0, min(page, resultsModel.totalPages - 1))
                }

                activity.append(.live(
                    kind: "set_results_view",
                    summary: "Adjusted the results table",
                    origin: .external(clientID: "set_results_view")))
                return .applied(.init(
                    filteredCount: resultsModel.filteredCount,
                    currentPage: resultsModel.currentPage,
                    totalPages: resultsModel.totalPages))
            }
        })
    }

    private func makeOpenObservationDetailTool() -> OpenObservationDetailTool {
        let activity = agentsService.activityStore
        return OpenObservationDetailTool(open: { [weak self] rowID in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let model = self.searchModel
                guard model.resultsModel.result(forID: rowID) != nil else {
                    return "No results row with id '\(rowID)' — ids come from get_search_results"
                }
                if self.currentMode != .search {
                    self.navigateTo(.search)
                }
                model.selectedTab = .results
                model.resultsModel.pendingDetailRequest = .init(rowID: rowID)
                activity.append(.live(
                    kind: "open_observation_detail",
                    summary: "Opened observation detail for \(rowID)",
                    origin: .external(clientID: "open_observation_detail")))
                return nil
            }
        })
    }

    // MARK: - FITS viewer control

    private func makeGetFITSViewTool() -> GetFITSViewTool {
        GetFITSViewTool(snapshot: { [weak self] in
            guard let self else { return Self.emptyFITSView() }
            return await self.fitsViewSnapshot()
        })
    }

    private func makeSetFITSViewTool() -> SetFITSViewTool {
        SetFITSViewTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await self.applyFITSView(args)
        })
    }

    private func makeFITSGotoCoordinateTool() -> FITSGotoCoordinateTool {
        FITSGotoCoordinateTool(goTo: { [weak self] ra, dec in
            guard let self else { return nil }
            return await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab, tab.wcs != nil else { return nil }
                return tab.goToCoordinate(ra: ra, dec: dec)
            }
        })
    }

    private func makeProbeFITSPixelTool() -> ProbeFITSPixelTool {
        ProbeFITSPixelTool(probe: { [weak self] x, y in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            return try await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab, let hdu = tab.selectedHDU else {
                    throw ToolFailureReason.targetNotResolved("No FITS image is open in the viewer")
                }
                guard let result = tab.probePixel(x: x, y: y) else {
                    throw ToolFailureReason.invalidArgument(
                        "pixel (\(x), \(y)) outside \(hdu.header.naxis1)×\(hdu.header.naxis2)")
                }
                return ProbeFITSPixelTool.Output(
                    x: x, y: y, value: result.value, raDeg: result.ra, decDeg: result.dec)
            }
        })
    }

    private func makeListFITSBookmarksTool() -> ListFITSBookmarksTool {
        ListFITSBookmarksTool(snapshot: { [weak self] in
            guard let self else { return [] }
            return await MainActor.run {
                let iso = ISO8601DateFormatter()
                return self.fitsBookmarks.bookmarks.map {
                    ListFITSBookmarksTool.Entry(
                        id: $0.id.uuidString, label: $0.label,
                        raDeg: $0.ra, decDeg: $0.dec,
                        sourceFilePath: $0.sourceFilePath,
                        savedAtISO: iso.string(from: $0.savedAt))
                }
            }
        })
    }

    private func makeListOpenTabsTool() -> ListOpenTabsTool {
        ListOpenTabsTool(snapshot: { [weak self] in
            guard let self else {
                return ListOpenTabsTool.Output(
                    fitsTabs: [], activeFITSTabIndex: nil, cubeOpen: false, cubeFileName: nil,
                    cubeTabs: [], activeCubeTabIndex: nil)
            }
            return await MainActor.run {
                let host = self.fitsTabHost
                let tabs = host.tabs.enumerated().map { index, tab in
                    ListOpenTabsTool.Output.Tab(
                        index: index,
                        path: tab.fileURL?.path ?? "",
                        isActive: index == host.activeTabIndex)
                }
                let cube = self.cubeViewer
                return ListOpenTabsTool.Output(
                    fitsTabs: tabs,
                    activeFITSTabIndex: host.tabs.isEmpty ? nil : host.activeTabIndex,
                    cubeOpen: cube.hasData,
                    cubeFileName: cube.hasData ? cube.fileName : nil,
                    cubeTabs: self.cubeTabHost.tabs.enumerated().map {
                        .init(index: $0.offset, path: $0.element.fileName, isActive: $0.offset == self.cubeTabHost.activeTabIndex)
                    },
                    activeCubeTabIndex: self.cubeTabHost.activeTabIndex)
            }
        })
    }

    private func makeCloseActiveTabTool() -> CloseActiveTabTool {
        let activity = agentsService.activityStore
        return CloseActiveTabTool(close: { [weak self] kind in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                guard kind == "fits" else { return "Unknown tab kind '\(kind)' — only \"fits\" tabs can be closed" }
                let host = self.fitsTabHost
                guard !host.tabs.isEmpty else { return "No FITS tabs are open" }
                host.closeActiveTab()
                activity.append(.live(
                    kind: "close_active_tab", summary: "Closed the active FITS tab",
                    origin: .external(clientID: "close_active_tab")))
                return nil
            }
        })
    }

    private nonisolated static func emptyFITSView() -> GetFITSViewTool.Output {
        GetFITSViewTool.Output(
            isOpen: false, filePath: nil, hduIndex: nil, imageWidth: nil, imageHeight: nil,
            stretch: nil, colormap: nil, minCut: nil, maxCut: nil, zoom: nil,
            rotationRadians: nil, crosshair: nil, openTabPaths: [], activeTabIndex: nil)
    }

    private func fitsViewSnapshot() -> GetFITSViewTool.Output {
        let host = fitsTabHost
        let paths = host.tabs.compactMap { $0.fileURL?.path }
        guard let tab = host.activeTab, let hdu = tab.selectedHDU else {
            var empty = Self.emptyFITSView()
            if !host.tabs.isEmpty {
                empty = GetFITSViewTool.Output(
                    isOpen: true, filePath: host.activeTab?.fileURL?.path,
                    hduIndex: host.activeTab?.selectedHDUIndex,
                    imageWidth: nil, imageHeight: nil, stretch: nil, colormap: nil,
                    minCut: nil, maxCut: nil, zoom: nil, rotationRadians: nil,
                    crosshair: nil, openTabPaths: paths, activeTabIndex: host.activeTabIndex)
            }
            return empty
        }
        var crosshair: GetFITSViewTool.Output.Crosshair?
        if let px = tab.crosshairPixel {
            crosshair = .init(
                x: px.x, y: px.y,
                raDeg: tab.crosshairRADeg, decDeg: tab.crosshairDecDeg,
                value: tab.crosshairValue)
        }
        return GetFITSViewTool.Output(
            isOpen: true,
            filePath: tab.fileURL?.path,
            hduIndex: tab.selectedHDUIndex,
            imageWidth: hdu.header.naxis1,
            imageHeight: hdu.header.naxis2,
            stretch: tab.renderParams.stretch.rawValue,
            colormap: tab.renderParams.colormap.rawValue,
            minCut: Double(tab.renderParams.minCut),
            maxCut: Double(tab.renderParams.maxCut),
            zoom: tab.viewport.zoom,
            rotationRadians: tab.viewport.rotation,
            crosshair: crosshair,
            openTabPaths: paths,
            activeTabIndex: host.activeTabIndex)
    }

    private func applyFITSView(_ args: SetFITSViewTool.Args) -> String? {
        let host = fitsTabHost
        if let idx = args.tabIndex {
            guard host.tabs.indices.contains(idx) else {
                return host.tabs.isEmpty
                    ? "No FITS tabs are open"
                    : "tabIndex \(idx) out of range 0…\(host.tabs.count - 1)"
            }
            host.activeTabIndex = idx
        }
        guard let tab = host.activeTab else { return "No FITS file is open in the viewer" }

        var needsRender = false
        if let s = args.stretch {
            guard let mode = FITSRenderParams.StretchMode(rawValue: s) else { return "Unknown stretch '\(s)'" }
            tab.renderParams.stretch = mode
            needsRender = true
        }
        if let c = args.colormap {
            guard let map = FITSRenderParams.ColormapType(rawValue: c) else { return "Unknown colormap '\(c)'" }
            tab.renderParams.colormap = map
            needsRender = true
        }
        let lo = args.minCut.map(Float.init) ?? tab.renderParams.minCut
        let hi = args.maxCut.map(Float.init) ?? tab.renderParams.maxCut
        if args.minCut != nil || args.maxCut != nil {
            guard lo < hi else { return "minCut must be < maxCut" }
            tab.renderParams.minCut = lo
            tab.renderParams.maxCut = hi
            needsRender = true
        }
        if needsRender { tab.renderImage() }

        if let z = args.zoom { tab.setZoom(z) }
        if args.fitToWindow == true {
            guard tab.lastCanvasSize.width > 0 else {
                return "The FITS viewer canvas hasn't been laid out yet — open the FITS Viewer first"
            }
            tab.fitToWindow(canvasSize: tab.lastCanvasSize)
        }
        if args.northUp == true { tab.applyNorthUp() }

        agentsService.activityStore.append(.live(
            kind: "set_fits_view", summary: "Adjusted the FITS view",
            origin: .external(clientID: "set_fits_view")))
        return nil
    }

    // MARK: - FITS viewer parity (HDU, auto-cut, blink, sync, export)

    private func makeSelectHDUTool() -> SelectHDUTool {
        let activity = agentsService.activityStore
        return SelectHDUTool(select: { [weak self] index in
            guard let self else { return "App state unavailable" }
            // Validate on the main actor, then run the (async, main-actor)
            // HDU switch outside the synchronous run block.
            let validated: (tab: FITSViewerModel?, error: String?) = await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab, let file = tab.file else {
                    return (nil, "No FITS file is open in the viewer")
                }
                guard file.hdus.indices.contains(index) else {
                    return (nil, "hduIndex \(index) out of range 0…\(file.hdus.count - 1)")
                }
                guard file.hdus[index].isImage else {
                    return (nil, "HDU \(index) is not an image HDU")
                }
                return (tab, nil)
            }
            if let message = validated.error { return message }
            guard let tab = validated.tab else { return "No FITS file is open in the viewer" }
            await tab.selectHDU(index)
            await MainActor.run {
                activity.append(.live(
                    kind: "select_hdu",
                    summary: "Selected HDU \(index)",
                    origin: .external(clientID: "select_hdu")))
            }
            return nil
        })
    }

    private func makeFITSAutoCutTool() -> FITSAutoCutTool {
        let activity = agentsService.activityStore
        return FITSAutoCutTool(autoCut: { [weak self] in
            guard let self else { return nil }
            return await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab, !tab.pixels.isEmpty else {
                    return nil
                }
                let cuts = FITSParser.autoCut(pixels: tab.pixels)
                tab.renderParams.minCut = cuts.min
                tab.renderParams.maxCut = cuts.max
                tab.renderImage()
                activity.append(.live(
                    kind: "fits_auto_cut",
                    summary: "Auto-computed display cuts",
                    origin: .external(clientID: "fits_auto_cut")))
                return FITSAutoCutTool.Cuts(min: Double(cuts.min), max: Double(cuts.max))
            }
        })
    }

    private func makeStartBlinkTool() -> StartBlinkTool {
        let activity = agentsService.activityStore
        return StartBlinkTool(start: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.tabs.count >= 2 else {
                    return .rejected("Blink needs at least 2 open FITS tabs")
                }
                let tabA = args.tabA ?? 0
                let tabB = args.tabB ?? 1
                guard host.tabs.indices.contains(tabA), host.tabs.indices.contains(tabB) else {
                    return .rejected("tab index out of range 0…\(host.tabs.count - 1)")
                }
                guard tabA != tabB else { return .rejected("tabA and tabB must differ") }
                if let interval = args.intervalSeconds { host.blinkInterval = interval }
                if self.currentMode != .fitsViewer { self.navigateTo(.fitsViewer) }
                host.startBlink(tabA: tabA, tabB: tabB)
                guard host.isBlinking else { return .rejected("Blink failed to start") }
                activity.append(.live(
                    kind: "start_blink",
                    summary: "Started blink: tab \(tabA) vs tab \(tabB)",
                    origin: .external(clientID: "start_blink")))
                return .started(.init(
                    tabA: tabA, tabB: tabB,
                    alignedWithWCS: host.blinkTransform != nil))
            }
        })
    }

    private func makeSetBlinkTool() -> SetBlinkTool {
        let activity = agentsService.activityStore
        return SetBlinkTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.isBlinking else {
                    return "No blink session is running — call start_blink first"
                }
                if let interval = args.intervalSeconds { host.blinkInterval = interval }
                if let show = args.show {
                    if show == "a" { host.showBlinkA() } else { host.showBlinkB() }
                }
                // Applied after `show` so an explicit paused value wins
                // over show's implicit pause.
                if let paused = args.paused, paused != host.isBlinkPaused {
                    host.toggleBlinkPause()
                }
                activity.append(.live(
                    kind: "set_blink",
                    summary: "Adjusted the blink session",
                    origin: .external(clientID: "set_blink")))
                return nil
            }
        })
    }

    private func makeStopBlinkTool() -> StopBlinkTool {
        let activity = agentsService.activityStore
        return StopBlinkTool(stop: { [weak self] in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.isBlinking else { return "No blink session is running" }
                host.stopBlink()
                activity.append(.live(
                    kind: "stop_blink",
                    summary: "Stopped the blink session",
                    origin: .external(clientID: "stop_blink")))
                return nil
            }
        })
    }

    private func makeBlinkFITSTabsTool() -> BlinkFITSTabsTool {
        BlinkFITSTabsTool(apply: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let host = self.fitsTabHost
                let action = args.action ?? (args.partnerTab == nil ? "start" : "start")
                if let interval = args.intervalSeconds { host.blinkInterval = interval }
                switch action {
                case "stop":
                    guard host.isBlinking else { return .rejected("No blink session is running") }
                    host.stopBlink()
                case "pause":
                    guard host.isBlinking else { return .rejected("No blink session is running") }
                    if !host.isBlinkPaused { host.toggleBlinkPause() }
                case "resume":
                    guard host.isBlinking else { return .rejected("No blink session is running") }
                    if host.isBlinkPaused { host.toggleBlinkPause() }
                case "start":
                    guard host.tabs.count >= 2 else { return .rejected("Blink needs at least 2 open FITS tabs") }
                    let partner = args.partnerTab ?? (host.activeTabIndex == 0 ? 1 : 0)
                    guard host.tabs.indices.contains(partner), partner != host.activeTabIndex else {
                        return .rejected("partnerTab must identify a different open FITS tab")
                    }
                    self.navigateTo(.fitsViewer)
                    host.startBlink(tabA: host.activeTabIndex, tabB: partner)
                default: return .rejected("Unknown action '\(action)'")
                }
                return .applied(.init(applied: true, isBlinking: host.isBlinking, paused: host.isBlinkPaused))
            }
        })
    }

    private func makeSwitchFITSTabTool() -> SwitchFITSTabTool {
        SwitchFITSTabTool(apply: { [weak self] index in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.tabs.indices.contains(index) else { return "index \(index) out of range 0…\(max(0, host.tabs.count - 1))" }
                self.navigateTo(.fitsViewer)
                host.activeTabIndex = index
                return nil
            }
        })
    }

    private func makeSetTabSyncTool() -> SetTabSyncTool {
        let activity = agentsService.activityStore
        return SetTabSyncTool(apply: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let host = self.fitsTabHost
                guard host.hasMultipleTabs else {
                    return .rejected("Tab sync needs at least 2 open FITS tabs")
                }
                if let link = args.linkCrosshair {
                    let wasOff = !host.linkedState.linkCrosshair
                    host.linkedState.linkCrosshair = link
                    if link && wasOff {
                        // The UI toggle norths-up unrotated tabs on enable so
                        // linked crosshairs land on consistently oriented views.
                        for tab in host.tabs where tab.viewport.rotation == 0 {
                            tab.applyNorthUp()
                        }
                    }
                }
                if let zoom = args.syncZoom { host.linkedState.linkZoom = zoom }
                activity.append(.live(
                    kind: "set_tab_sync",
                    summary: "Adjusted tab sync (crosshair: \(host.linkedState.linkCrosshair), zoom: \(host.linkedState.linkZoom))",
                    origin: .external(clientID: "set_tab_sync")))
                return .applied(.init(
                    linkCrosshair: host.linkedState.linkCrosshair,
                    syncZoom: host.linkedState.linkZoom,
                    usesImpreciseWCS: host.syncUsesImpreciseWCS))
            }
        })
    }

    private func makeSearchAtCrosshairTool() -> SearchAtCrosshairTool {
        let activity = agentsService.activityStore
        return SearchAtCrosshairTool(run: { [weak self] in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                guard let tab = self.fitsTabHost.activeTab,
                      let ra = tab.crosshairRADeg, let dec = tab.crosshairDecDeg else {
                    return .rejected("No crosshair with sky coordinates — place one with fits_goto_coordinate")
                }
                self.dispatch(.searchCoordinates(ra: ra, dec: dec))
                activity.append(.live(
                    kind: "search_at_crosshair",
                    summary: String(format: "Searching at crosshair (%.4f°, %+0.4f°)", ra, dec),
                    origin: .external(clientID: "search_at_crosshair")))
                return .applied(raDeg: ra, decDeg: dec)
            }
        })
    }

    // MARK: - Cube viewer control

    private nonisolated static func closedCubeView() -> GetCubeViewTool.Output {
        GetCubeViewTool.Output(
            isOpen: false, fileName: nil, nx: nil, ny: nil, nz: nil, channel: nil,
            viewMode: nil, colormap: nil, stretch: nil, windowLo: nil, windowHi: nil,
            density: nil, maxIntensityProjection: nil, autoOrbit: nil, isPlaying: nil,
            background: nil, spectralScale: nil, quality: nil, showSlicePlane: nil,
            playbackFPS: nil, opacityCurve: nil, camera: nil)
    }

    private func makeGetCubeViewTool() -> GetCubeViewTool {
        GetCubeViewTool(snapshot: { [weak self] in
            guard let self else { return Self.closedCubeView() }
            return await MainActor.run {
                let model = self.cubeViewer
                guard model.hasData else { return Self.closedCubeView() }
                return GetCubeViewTool.Output(
                    isOpen: true,
                    fileName: model.fileName,
                    nx: model.nx, ny: model.ny, nz: model.nz,
                    channel: model.channel,
                    viewMode: model.viewMode == .slice ? "slice" : "volume",
                    colormap: model.colormap.rawValue,
                    stretch: model.stretch.rawValue,
                    windowLo: Double(model.windowLo),
                    windowHi: Double(model.windowHi),
                    density: Double(model.density),
                    maxIntensityProjection: model.mip,
                    autoOrbit: model.autoOrbit,
                    isPlaying: model.isPlaying,
                    background: model.background.rawValue,
                    spectralScale: Double(model.spectralScale),
                    quality: Double(model.volumeSteps),
                    showSlicePlane: model.showSlicePlane,
                    playbackFPS: model.playbackFPS,
                    opacityCurve: model.transferFunction.map { [Double($0.x), Double($0.y)] },
                    camera: .init(
                        azimuthDeg: Double(model.cameraAzimuth) * 180 / .pi,
                        elevationDeg: Double(model.cameraElevation) * 180 / .pi,
                        distance: Double(model.cameraDistance)))
            }
        })
    }

    private func makeSetCubeViewTool() -> SetCubeViewTool {
        let activity = agentsService.activityStore
        return SetCubeViewTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let model = self.cubeViewer
                guard model.hasData else { return "No cube is open in the Cube Viewer" }
                if let mode = args.viewMode {
                    switch mode {
                    case "slice": model.viewMode = .slice
                    case "volume": model.viewMode = .volume
                    default: return "Unknown viewMode '\(mode)'"
                    }
                }
                if let ch = args.channel {
                    guard ch >= 0 && ch < model.nz else {
                        return "channel \(ch) out of range 0…\(model.nz - 1)"
                    }
                    model.setChannel(ch)
                }
                if let c = args.colormap {
                    guard let map = FITSRenderParams.ColormapType(rawValue: c) else { return "Unknown colormap '\(c)'" }
                    model.colormap = map
                }
                if let s = args.stretch {
                    guard let mode = FITSRenderParams.StretchMode(rawValue: s) else { return "Unknown stretch '\(s)'" }
                    model.stretch = mode
                }
                if args.windowLo != nil || args.windowHi != nil {
                    let lo = args.windowLo.map(Float.init) ?? model.windowLo
                    let hi = args.windowHi.map(Float.init) ?? model.windowHi
                    guard lo < hi else { return "windowLo must be < windowHi" }
                    model.windowLo = lo
                    model.windowHi = hi
                }
                if let d = args.density {
                    guard d >= 0 else { return "density must be ≥ 0" }
                    model.density = Float(d)
                }
                if let mip = args.maxIntensityProjection { model.mip = mip }
                if let orbit = args.autoOrbit { model.autoOrbit = orbit }
                if let playing = args.playing {
                    if playing { model.startPlayback() } else { model.stopPlayback() }
                }
                if let bg = args.background {
                    guard let value = CubeBackground(rawValue: bg) else { return "Unknown background '\(bg)'" }
                    model.background = value
                }
                if let scale = args.spectralScale {
                    guard (0.5...4).contains(scale) else { return "spectralScale must be 0.5–4" }
                    model.spectralScale = Float(scale)
                }
                if let quality = args.quality {
                    guard (96...768).contains(quality) else { return "quality must be 96–768" }
                    model.volumeSteps = Float(quality)
                }
                if let marker = args.showSlicePlane { model.showSlicePlane = marker }
                if let fps = args.playbackFPS {
                    guard (0.5...60).contains(fps) else { return "playbackFPS must be 0.5–60" }
                    model.playbackFPS = fps
                }
                if let curve = args.opacityCurve {
                    if let error = SetCubeViewTool.validateOpacityCurve(curve) { return error }
                    model.transferFunction = curve.map { SIMD2(Float($0[0]), Float($0[1])) }
                }
                if let auto = args.autoWindow {
                    switch auto {
                    case "percentile": model.autoWindowPercentile()
                    case "full": model.autoWindowFullRange()
                    default: return "Unknown autoWindow '\(auto)' — use percentile or full"
                    }
                }
                // The UI's bindings request a slice re-render on every
                // slice-affecting change; tool-driven mutations must too,
                // or the slice pane goes stale until the next interaction.
                if args.colormap != nil || args.stretch != nil
                    || args.windowLo != nil || args.windowHi != nil {
                    model.requestSliceRender()
                }
                if args.reveal == true { self.navigateTo(.cubeViewer) }
                activity.append(.live(
                    kind: "set_cube_view", summary: "Adjusted the Cube view",
                    origin: .external(clientID: "set_cube_view")))
                return nil
            }
        })
    }

    private func makeSetCubeCameraTool() -> SetCubeCameraTool {
        let activity = agentsService.activityStore
        return SetCubeCameraTool(apply: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let model = self.cubeViewer
                guard model.hasData else { return .rejected("No cube is open in the Cube Viewer") }
                if let z = args.zoomFactor, z <= 0 { return .rejected("zoomFactor must be > 0") }

                let degToRad = Float.pi / 180
                var azimuth = args.azimuthDeg.map { Float($0) * degToRad } ?? model.cameraAzimuth
                var elevation = args.elevationDeg.map { Float($0) * degToRad } ?? model.cameraElevation
                var distance = args.distance.map(Float.init) ?? model.cameraDistance
                if let d = args.orbitByAzimuthDeg { azimuth += Float(d) * degToRad }
                if let d = args.orbitByElevationDeg { elevation += Float(d) * degToRad }
                if let z = args.zoomFactor { distance /= Float(z) }
                elevation = min(max(elevation, -1.4), 1.4)
                distance = min(max(distance, 0.5), 8)

                // The camera only exists in volume mode — switch so the
                // user actually sees the move.
                if model.viewMode != .volume { model.viewMode = .volume }
                if args.reveal == true { self.navigateTo(.cubeViewer) }

                let duration = (self.reduceMotion || args.animated == false) ? 0 : 0.6
                model.animateCamera(
                    azimuth: azimuth, elevation: elevation, distance: distance,
                    duration: duration)

                activity.append(.live(
                    kind: "set_cube_camera", summary: "Moved the Cube camera",
                    origin: .external(clientID: "set_cube_camera")))
                return .applied(SetCubeCameraTool.Pose(
                    azimuthDeg: Double(azimuth) * 180 / .pi,
                    elevationDeg: Double(elevation) * 180 / .pi,
                    distance: Double(distance)))
            }
        })
    }

    private func makeProbeCubeSpectrumTool() -> ProbeCubeSpectrumTool {
        ProbeCubeSpectrumTool(probe: { [weak self] x, y in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            return try await self.probeCubeSpectrum(x: x, y: y)
        })
    }

    private func makeListRecentCubesTool() -> ListRecentCubesTool {
        ListRecentCubesTool(snapshot: { [weak self] in
            guard let self else { return [] }
            return await MainActor.run {
                self.cubeViewer.recents.map { .init(name: $0.name, path: $0.path) }
            }
        })
    }

    private func makeShowCubeSpectrumTool() -> ShowCubeSpectrumTool {
        ShowCubeSpectrumTool(apply: { [weak self] visible in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                guard self.cubeViewer.hasData else { return "No cube is open in the Cube Viewer" }
                self.cubeViewer.showSpectrumPanel = visible
                self.navigateTo(.cubeViewer)
                return nil
            }
        })
    }

    private func makeGetCubeChannelProfileTool() -> GetCubeChannelProfileTool {
        GetCubeChannelProfileTool(profile: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                let cube = self.cubeViewer
                guard cube.hasData else { throw ToolFailureReason.targetNotResolved("No cube is open in the Cube Viewer") }
                let means = cube.channelProfile ?? []
                return GetCubeChannelProfileTool.Output(
                    channelCount: cube.nz,
                    means: means.map { $0.isFinite ? Double($0) : nil },
                    spectralAxis: (0..<cube.nz).map { cube.wcs?.spectral.format(channel: $0).primary })
            }
        })
    }

    private func makeSetCubeTransferTool() -> SetCubeTransferTool {
        SetCubeTransferTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let cube = self.cubeViewer
                guard cube.hasData else { return "No cube is open in the Cube Viewer" }
                if args.reset == true {
                    cube.transferFunction = [SIMD2(0, 0), SIMD2(0.45, 0.05), SIMD2(0.75, 0.45), SIMD2(1, 1)]
                } else if let curve = args.opacityCurve {
                    if let error = SetCubeViewTool.validateOpacityCurve(curve) { return error }
                    cube.transferFunction = curve.map { SIMD2(Float($0[0]), Float($0[1])) }
                } else { return "Pass opacityCurve or reset: true" }
                self.navigateTo(.cubeViewer)
                return nil
            }
        })
    }

    private func makeSwitchCubeTabTool() -> SwitchCubeTabTool {
        SwitchCubeTabTool(apply: { [weak self] index in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                guard self.cubeTabHost.tabs.indices.contains(index) else {
                    return "index \(index) out of range 0…\(max(0, self.cubeTabHost.tabs.count - 1))"
                }
                self.cubeTabHost.activeTabIndex = index
                self.navigateTo(.cubeViewer)
                return nil
            }
        })
    }

    private func probeCubeSpectrum(x: Int, y: Int) async throws -> ProbeCubeSpectrumTool.Output {
        let model = cubeViewer
        guard model.hasData else {
            throw ToolFailureReason.targetNotResolved(
                "No cube is open in the Cube Viewer — call navigate_to(mode: cubeViewer) after open_cube, or open a cube first.")
        }
        guard x >= 0, y >= 0, x < model.nx, y < model.ny else {
            throw ToolFailureReason.invalidArgument("pixel (\(x), \(y)) outside \(model.nx)×\(model.ny)")
        }
        if model.isStreamed {
            throw ToolFailureReason.invalidArgument(
                "Spectrum probe needs the whole cube in RAM. This cube is streamed (too large to load fully). Use get_cube_view / get_cube_channel_profile instead — do not request a full in-memory load (OOM risk).")
        }
        await model.probe(x: x, y: y)
        guard let spectrum = model.probeSpectrum else {
            throw ToolFailureReason.backendError(model.probeUnavailableReason ?? "spectrum unavailable")
        }
        return ProbeCubeSpectrumTool.Output(
            x: x, y: y,
            channelCount: model.nz,
            spectrum: spectrum.prefix(8192).map { $0.isFinite ? Double($0) : nil },
            blankedChannels: spectrum.prefix(8192).enumerated().compactMap { $0.element.isFinite ? nil : $0.offset },
            truncated: spectrum.count > 8192)
    }
}
