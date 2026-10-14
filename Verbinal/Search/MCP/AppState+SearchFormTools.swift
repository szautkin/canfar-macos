// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Search: the live search form — its fields, the data train, its tabs, quick search — as an assistant fills it.
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

    // MARK: - Search form/results control

    /// Map the app's `IntentValue` / `DatePresetValue` to the agent-facing
    /// keys (the raw values are TAP wire strings like "" that read poorly
    /// in a tool result).
    nonisolated static func intentKey(_ intent: IntentValue) -> String {
        switch intent {
        case .any: return "any"
        case .science: return "science"
        case .calibration: return "calibration"
        }
    }

    nonisolated static func datePresetKey(_ preset: DatePresetValue) -> String {
        switch preset {
        case .none: return "none"
        case .past24Hours: return "past24Hours"
        case .pastWeek: return "pastWeek"
        case .pastMonth: return "pastMonth"
        }
    }

    /// What a search asked to run tells the agent — the form and the editor
    /// tools report it the same way. A query the checker refused was not
    /// executed, and says why.
    nonisolated static func report(
        _ outcome: SearchFormModel.SearchOutcome
    ) -> (executed: Bool, resultCount: Int?, searchError: String?, cancelled: Bool) {
        switch outcome {
        case .completed(let rows): return (true, rows, nil, false)
        case .failed(let message): return (true, nil, message, false)
        case .cancelled: return (true, nil, nil, true)
        case .refused(let reason): return (false, nil, reason, false)
        }
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
    nonisolated static func intent(forKey key: String) -> IntentValue? {
        IntentValue.allCases.first { intentKey($0) == key }
    }

    /// Inverse of ``datePresetKey(_:)``.
    nonisolated static func datePreset(forKey key: String) -> DatePresetValue? {
        DatePresetValue.allCases.first { datePresetKey($0) == key }
    }

    /// Resolver coordinates in the exact shape `ADQLBuilder.buildQuery`
    /// and `executeSearch` consume.
    @MainActor
    static func resolverCoords(of model: SearchFormModel) -> (ra: String, dec: String)? {
        guard let result = model.resolverResult, !result.coordsRA.isEmpty else { return nil }
        return (ra: result.coordsRA, dec: result.coordsDec)
    }

    nonisolated static let emptySearchForm = GetSearchFormTool.Output(
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
                switch model.resolution {
                case .idle: statusKey = "idle"
                case .working: statusKey = "resolving"
                case .ready(let result):
                    statusKey = "resolved"
                    resolvedRA = result.coordsRA
                    resolvedDec = result.coordsDec
                case .failed(let problem, _): statusKey = "failed: \(problem.message)"
                }
                var form = GetSearchFormTool.Output(
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
                form.searchRadius = SpatialBuilder.radiusDegrees(state.searchRadius) ?? ADQL.defaultSearchRadius
                return form
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
                guard let value = ResolverValue(named: raw) else {
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
                if let v = args.searchRadius { state.searchRadius = v > 0 ? String(v) : "" }
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
                if args.wait == false {
                    // Started, not awaited: cancel_search can stop it (plan 30 R2).
                    Task { @MainActor in _ = await model.executeSearch() }
                    outcome.started = true
                } else {
                    (outcome.executed, outcome.resultCount, outcome.searchError, outcome.cancelled) =
                        Self.report(await model.executeSearch())
                }
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
                    error: dataTrain.load.problem?.message)
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
                if let problem = dataTrain.load.problem {
                    return RefreshDataTrainTool.Refreshed(error: problem.message, lastRefreshedISO: nil)
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
}
