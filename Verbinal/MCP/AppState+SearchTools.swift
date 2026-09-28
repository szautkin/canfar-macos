// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Search: archive queries, target resolution, DataLink, saved and recent
/// searches, and control of the live search form, ADQL editor and results.
extension AppState {
    // MARK: - Focus

    func makeSetSearchFocusTool() -> SetSearchFocusTool {
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

    // MARK: - Export

    /// Export current in-app results (when `adql` is omitted) or a
    /// caller-supplied TAP query. Matches `get_search_results` for the
    /// omit-adql path so agents can dump what the user is looking at.
    func runSearchExport(
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
        var components = URLComponents(string: TAPConfig.syncURL)
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
        let dest = FileHelper.timestampedDownloadsURL(stem: "verbinal-results", ext: ext)
        try FileHelper.moveReplacing(from: tempURL, to: dest)
        return dest.path
    }

    // MARK: - Search domain

    func makeSearchObservationsTool(tap: TAPClient,
                                            resolver: TargetResolverService) -> SearchObservationsTool {
        SearchObservationsTool(
            runQuery: { adql, maxRec in
                try await tap.tapQueryRows(adql: adql, maxRec: maxRec)
            },
            resolveTarget: { name in
                let result = try await resolver.resolve(target: name, service: .all)
                // CADC's resolver returns RA/Dec as strings — usually
                // decimal degrees but some shapes ship sexagesimal; the
                // Sexagesimal readers take either. Trailing CR/LF is
                // already stripped by the resolver parser (F-12 fix in
                // TAPClient.parseResolverResponse), so a string neither
                // reads means we genuinely failed to resolve. (Closes F-9
                // of the platform review.)
                guard let ra = Sexagesimal.rightAscension(result.coordsRA),
                      let dec = Sexagesimal.declination(result.coordsDec) else {
                    throw ToolFailureReason.targetNotResolved(name)
                }
                return (ra: ra, dec: dec)
            }
        )
    }

    func makeVizierConeSearchTool(tap: TAPClient) -> VizierConeSearchTool {
        VizierConeSearchTool(search: { catalogue, ra, dec, radius, raCol, decCol, columns, max in
            try await tap.vizierConeSearch(
                catalogue: catalogue,
                raDeg: ra, decDeg: dec, radiusDeg: radius,
                raColumn: raCol, decColumn: decCol, columns: columns,
                maxRec: max
            )
        })
    }

    func makeResolveTargetTool(resolver: TargetResolverService) -> ResolveTargetTool {
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
            let raDeg = Sexagesimal.rightAscension(r.coordsRA)
            let decDeg = Sexagesimal.declination(r.coordsDec)
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

    func makeGetObservationCAOM2Tool(caom2: CAOM2Service) -> GetObservationCAOM2Tool {
        GetObservationCAOM2Tool(fetch: { id in
            try await caom2.fetch(publisherID: id)
        })
    }

    func makeGetDataLinksTool(tap: TAPClient, caom2: CAOM2Service) -> GetDataLinksTool {
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
                packageDownloadURL: TAPClient.downloadURL(publisherID: id),
                faults: r.faults
            )
        })
    }

    func makeGetPreviewImageTool(network: NetworkClient, caom2: CAOM2Service) -> GetPreviewImageTool {
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

    func makeListRecentSearchesTool(store: RecentSearchStore) -> ListRecentSearchesTool {
        ListRecentSearchesTool(snapshot: { @MainActor in
            store.searches.map { .init(id: $0.id, name: $0.name, savedAt: $0.savedAt, adql: $0.adql) }
        })
    }

    func makeListSavedQueriesTool(store: SavedQueryStore) -> ListSavedQueriesTool {
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

    func makeGetSavedQueryTool(store: SavedQueryStore) -> GetSavedQueryTool {
        GetSavedQueryTool(lookup: { @MainActor id in
            guard let q = store.queries.first(where: { $0.id == id }) else { return nil }
            return SavedQueryRow(
                id: q.id, name: q.name, adql: q.adql,
                savedAt: q.savedAt,
                description: q.description, tags: q.tags
            )
        })
    }

    // MARK: - Search form loading

    func makeLoadSavedSearchTool(
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
                    self.pendingSearchLoad = AppState.PendingSearchLoad(
                    kind: recent.adql.map { .adql($0) } ?? .snapshot(recent.formSnapshot))
                    self.navigateTo(.search)
                    activity.append(.live(
                        kind: "load_saved_search",
                        summary: "Loaded recent search '\(recent.name)' into the \(recent.isFromEditor ? "ADQL editor" : "form")",
                        origin: .external(clientID: "load_saved_search")))
                    return nil
                }
                return "Pass savedQueryID or recentSearchID"
            }
        })
    }

    func makeLoadRecentSearchTool(recentStore: RecentSearchStore) -> LoadRecentSearchTool {
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
                self.pendingSearchLoad = AppState.PendingSearchLoad(
                    kind: recent.adql.map { .adql($0) } ?? .snapshot(recent.formSnapshot))
                self.navigateTo(.search)
                activity.append(.live(
                    kind: "load_recent_search",
                    summary: "Loaded recent search '\(recent.name)' into the \(recent.isFromEditor ? "ADQL editor" : "form")",
                    origin: .external(clientID: "load_recent_search")))
                return nil
            }
        })
    }

    func makeRunSavedQueryTool(savedStore: SavedQueryStore) -> RunSavedQueryTool {
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

    /// What an executed search tells the agent — the form and the editor
    /// tools report it the same way.
    private nonisolated static func report(
        _ outcome: SearchFormModel.SearchOutcome
    ) -> (resultCount: Int?, searchError: String?, cancelled: Bool) {
        switch outcome {
        case .completed(let rows): return (rows, nil, false)
        case .failed(let message): return (nil, message, false)
        case .cancelled: return (nil, nil, true)
        }
    }

    /// The search model's schema service, fetched on first use.
    private func tapSchemaSource() -> @Sendable () async throws -> TapSchema {
        let service = searchModel.tapSchema
        return { try await service.schema() }
    }

    func makeDescribeTapSchemaTool() -> DescribeTapSchemaTool {
        DescribeTapSchemaTool(schema: tapSchemaSource())
    }

    func makeValidateADQLQueryTool() -> ValidateADQLQueryTool {
        ValidateADQLQueryTool(schema: tapSchemaSource())
    }

    func makeCancelSearchTool() -> CancelSearchTool {
        let activity = agentsService.activityStore
        return CancelSearchTool(cancel: { [weak self] in
            guard let self else { return false }
            return await MainActor.run {
                let model = self.searchModel
                guard model.isSearching else { return false }
                model.cancelSearch()
                activity.append(.live(
                    kind: "cancel_search",
                    summary: "Cancelled the running search",
                    origin: .external(clientID: "cancel_search")))
                return true
            }
        })
    }

    /// Inverse of ``intentKey(_:)`` — one mapping, read both ways.
    private nonisolated static func intent(forKey key: String) -> IntentValue? {
        IntentValue.allCases.first { intentKey($0) == key }
    }

    /// Inverse of ``datePresetKey(_:)``.
    private nonisolated static func datePreset(forKey key: String) -> DatePresetValue? {
        DatePresetValue.allCases.first { datePresetKey($0) == key }
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
        target: "", resolver: "all", pixelScale: "", spatialCutout: false,
        resolverStatus: "idle", resolvedRA: nil, resolvedDec: nil,
        observationDate: "", datePreset: "none", integrationTime: "", timeSpan: "",
        spectralCoverage: "", spectralSampling: "", resolvingPower: "",
        bandpassWidth: "", restFrameEnergy: "", spectralCutout: false,
        bands: [], collections: [], instruments: [], filters: [],
        calLevels: [], dataTypes: [], obsTypes: [],
        selectedTab: "search", isSearching: false, searchError: nil,
        generatedADQL: "")

    func makeGetSearchFormTool() -> GetSearchFormTool {
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
                    spatialCutout: state.spatialCutout,
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
                    spectralCutout: state.spectralCutout,
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

    func makeSetSearchFormTool() -> SetSearchFormTool {
        let activity = agentsService.activityStore
        return SetSearchFormTool(apply: { [weak self] args in
            guard let self else { return .init(error: "App state unavailable") }

            // Map enum-ish strings up front so bad values reject cleanly
            // before any form mutation.
            let intent: IntentValue?
            if let raw = args.intent {
                guard let value = Self.intent(forKey: raw) else {
                    return .init(error: "Unknown intent '\(raw)'")
                }
                intent = value
            } else {
                intent = nil
            }
            let resolver: ResolverValue?
            if let raw = args.resolver {
                guard let value = ResolverValue(rawValue: raw.uppercased()) else {
                    return .init(error: "Unknown resolver '\(raw)'")
                }
                resolver = value
            } else {
                resolver = nil
            }
            let datePreset: DatePresetValue?
            if let raw = args.datePreset {
                guard let value = Self.datePreset(forKey: raw) else {
                    return .init(error: "Unknown datePreset '\(raw)'")
                }
                datePreset = value
            } else {
                datePreset = nil
            }

            let model = self.searchModel
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
                if let v = args.spatialCutout { state.spatialCutout = v }
                if let v = args.spectralCutout { state.spectralCutout = v }

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
                let report = Self.report(await model.executeSearch())
                outcome.executed = true
                (outcome.resultCount, outcome.searchError, outcome.cancelled) = report
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

    func makeResetSearchFormTool() -> ResetSearchFormTool {
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

    func makeGetDataTrainOptionsTool() -> GetDataTrainOptionsTool {
        GetDataTrainOptionsTool(snapshot: { [weak self] in
            guard let self else {
                return .init(columns: [], lastRefreshedISO: nil,
                             isRefreshing: false, error: "App state unavailable")
            }
            let model = self.searchModel
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

    func makeRefreshDataTrainTool() -> RefreshDataTrainTool {
        let activity = agentsService.activityStore
        return RefreshDataTrainTool(refresh: { [weak self] in
            guard let self else {
                return .init(error: "App state unavailable", lastRefreshedISO: nil)
            }
            let model = self.searchModel
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

    func makeSetADQLEditorTool() -> SetADQLEditorTool {
        let activity = agentsService.activityStore
        return SetADQLEditorTool(apply: { [weak self] args in
            guard let self else { return .init(error: "App state unavailable") }
            let model = self.searchModel
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
                await MainActor.run {
                    model.nextSearchAttribution = .forLiveTool(
                        label: "set_adql_editor", summary: "Ran a query from the ADQL editor")
                }
                let report = Self.report(await model.executeRawQuery(adql, fromEditor: true))
                outcome.executed = true
                (outcome.resultCount, outcome.searchError, outcome.cancelled) = report
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

    func makeSelectSearchTabTool() -> SelectSearchTabTool {
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

    func makeQuickSearchTool() -> QuickSearchTool {
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
            let model = self.searchModel
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

    func makeGetSearchResultsTool() -> GetSearchResultsTool {
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

    func makeSetResultsViewTool() -> SetResultsViewTool {
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

    /// Opens the detail sheet for a loaded results row — the one path the
    /// three detail tools share. Returns why not, or nil.
    @MainActor
    private func openObservationDetail(rowID: String, via tool: String) -> String? {
        let model = searchModel
        guard model.resultsModel.result(forID: rowID) != nil else {
            return "No results row with id '\(rowID)' — ids come from get_search_results"
        }
        if currentMode != .search { navigateTo(.search) }
        model.selectedTab = .results
        model.resultsModel.pendingDetailRequest = .init(rowID: rowID)
        agentsService.activityStore.append(.live(
            kind: tool, summary: "Opened observation detail for \(rowID)", origin: .external(clientID: tool)))
        return nil
    }

    func makeOpenObservationDetailTool() -> LiveActionTool<ObservationDetailActions.RowIDArgs> {
        ObservationDetailActions.openByRowID { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await self.openObservationDetail(rowID: args.rowID, via: "open_observation_detail")
        }
    }

    func makeShowSearchRowDetailTool() -> LiveActionTool<ObservationDetailActions.RowArgs> {
        ObservationDetailActions.openByRow { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let rows = self.searchModel.resultsModel.displayedRows
                guard rows.indices.contains(args.row) else {
                    return rows.isEmpty
                        ? "No results on screen — run a search first"
                        : "row \(args.row) is not on the page shown (0…\(rows.count - 1))"
                }
                return self.openObservationDetail(rowID: rows[args.row].id, via: "show_search_row_detail")
            }
        }
    }

    func makeShowObservationDetailTool() -> LiveActionTool<ObservationDetailActions.PublisherArgs> {
        ObservationDetailActions.openByPublisherID { [weak self] args in
            guard let self else { return "App state unavailable" }
            let wanted = args.publisherId.trimmingCharacters(in: .whitespaces)
            return await MainActor.run {
                guard let row = self.searchModel.resultsModel.result(publisherID: wanted) else {
                    return "\(wanted) is not among the current search results — search for it first (set_search_form with its observationID), then call this again"
                }
                return self.openObservationDetail(rowID: row.id, via: "show_observation_detail")
            }
        }
    }
}
