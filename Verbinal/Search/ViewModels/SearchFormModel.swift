// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// Orchestrates the search form: form state, target resolution, query building, search execution,
/// and persistence (recent searches, saved queries).
@Observable
@MainActor
final class SearchFormModel {
    let formState = SearchFormState()
    let resultsModel = SearchResultsModel()
    let dataTrainModel: DataTrainModel
    let recentSearchStore: RecentSearchStore
    let savedQueryStore: SavedQueryStore

    let tapClient: TAPClient
    /// The archive's TAP_SCHEMA, shared by the ADQL editor's checker and
    /// the agent tools.
    let tapSchema: TapSchemaService
    private let resolverService: TargetResolverService

    // Target resolution state
    var resolverStatus: ResolverStatus = .idle
    var resolverResult: ResolverResult?

    // Search execution state
    var isSearching = false
    /// When the running search began — the screen says how long it has waited.
    private(set) var searchStartedAt: Date?
    var searchError: String?

    /// How a search ended. Agent tools report it: a search the person
    /// cancelled is neither a result nor an error, and one the checker
    /// refused was never sent (QA L13).
    enum SearchOutcome: Equatable, Sendable {
        case completed(rows: Int)
        case failed(String)
        case cancelled
        case refused(String)
    }

    /// The query in flight; `cancelSearch()` stops it.
    private var runningQuery: Task<(headers: [String], rows: [[String]]), Error>?

    // Tab state
    enum SearchTab: String, CaseIterable, Identifiable {
        case search, results, adql
        var id: String { rawValue }
    }
    var selectedTab: SearchTab = .search

    // Debounce task for target resolution
    private var resolveTask: Task<Void, Never>?

    /// One-shot attribution consumed by the next auto-saved recent
    /// search. The agent-search wiring sets this before calling
    /// `executeSearch()` so the resulting Recent Searches row carries the
    /// agent badge; user-run searches leave it nil. Cleared on every
    /// auto-save attempt so it can never leak onto a later user search.
    var nextSearchAttribution: AgentAttribution?

    // Stores are constructed inside the @MainActor init body so the
    // strict-concurrency check doesn't reject parameter defaults
    // evaluated in the caller's isolation context (the SwiftUI
    // @State property-wrapper init position isn't always inferred
    // MainActor at the syntactic call site).
    init(tapClient: TAPClient = TAPClient(),
         recentSearchStore: RecentSearchStore? = nil,
         savedQueryStore: SavedQueryStore? = nil) {
        self.tapClient = tapClient
        self.tapSchema = TapSchemaService(tapClient: tapClient)
        self.recentSearchStore = recentSearchStore ?? RecentSearchStore()
        self.savedQueryStore = savedQueryStore ?? SavedQueryStore()
        self.resolverService = TargetResolverService(tapClient: tapClient)
        self.dataTrainModel = DataTrainModel(
            dataTrainService: DataTrainService(tapClient: tapClient)
        )
    }

    // MARK: - Coordinate Pre-population

    /// Pre-populate the search form with sky coordinates (decimal degrees) from an
    /// external source such as the FITS viewer crosshair. Sets `resolver = .none`
    /// since we already have resolved coordinates — no name lookup needed.
    func setSearchCoordinates(ra: Double, dec: Double) {
        formState.target = String(format: "%.6f %.6f", ra, dec)
        formState.resolver = .none
        resolverStatus = .idle
        resolverResult = nil
        resolveTask?.cancel()
        selectedTab = .search
    }

    // MARK: - Target Resolution

    func targetChanged() {
        resolveTask?.cancel()

        let target = formState.target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, formState.resolver != .none else {
            resolverStatus = .idle
            resolverResult = nil
            return
        }

        resolverStatus = .resolving
        resolveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            do {
                let result = try await resolverService.resolve(
                    target: target,
                    service: formState.resolver
                )
                guard !Task.isCancelled else { return }
                resolverResult = result
                if !result.coordsRA.isEmpty && !result.coordsDec.isEmpty {
                    resolverStatus = .resolved(ra: result.coordsRA, dec: result.coordsDec)
                } else {
                    resolverStatus = .failed("No coordinates found")
                }
            } catch {
                guard !Task.isCancelled else { return }
                resolverResult = nil
                resolverStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Resolve the current target immediately (no debounce) and wait for
    /// the outcome. The `set_search_form` agent tool uses this so an
    /// immediate `execute` sees resolver coordinates the same way a user
    /// who paused after typing would.
    func resolveTargetNow() async {
        resolveTask?.cancel()
        let target = formState.target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, formState.resolver != .none else {
            resolverStatus = .idle
            resolverResult = nil
            return
        }
        resolverStatus = .resolving
        do {
            let result = try await resolverService.resolve(
                target: target,
                service: formState.resolver
            )
            resolverResult = result
            if !result.coordsRA.isEmpty && !result.coordsDec.isEmpty {
                resolverStatus = .resolved(ra: result.coordsRA, dec: result.coordsDec)
            } else {
                resolverStatus = .failed("No coordinates found")
            }
        } catch {
            resolverResult = nil
            resolverStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: - Search (from form)

    /// The resolved target's position, when the resolver found one.
    var resolverCoords: (ra: String, dec: String)? {
        guard let result = resolverResult, !result.coordsRA.isEmpty else { return nil }
        return (ra: result.coordsRA, dec: result.coordsDec)
    }

    /// The search's cutout boxes, with what they cut to.
    var searchCutout: SearchCutout {
        SearchCutout(hints: cutoutHints, spatial: formState.spatialCutout, spectral: formState.spectralCutout)
    }

    /// What the search asks for that a cutout of one of its results can
    /// start from: its circle and its wavelengths, read by the builders
    /// that write the query.
    var cutoutHints: CutoutHints? {
        let circle = SpatialBuilder.circle(SpatialBuilder.Params(
            target: formState.target, resolver: formState.resolver,
            resolverCoords: resolverCoords, pixelScale: formState.pixelScale))
        let band = SpectralBuilder.coverageInterval(formState.spectralCoverage)
        guard circle != nil || band != nil else { return nil }
        return CutoutHints(ra: circle?.ra, dec: circle?.dec, radius: circle?.radius, bandMin: band?.min, bandMax: band?.max)
    }

    @discardableResult
    func executeSearch() async -> SearchOutcome {
        let attribution = takeAttribution()

        let query = ADQLBuilder.buildQuery(
            formState: formState,
            resolverCoords: resolverCoords
        )

        let outcome = await runQuery(query)
        // Only a search that ran is worth finding again.
        if case .completed = outcome {
            let snapshot = formState.toSnapshot()
            if snapshot != SearchFormSnapshot() {
                recentSearchStore.save(RecentSearch(
                    name: snapshot.autoName(), formSnapshot: snapshot, agentAttribution: attribution))
            }
        }
        return outcome
    }

    /// The Cancel button beside the spinner. Rows already shown stay; a
    /// newer search supersedes an older one on its own.
    func cancelSearch() {
        runningQuery?.cancel()
    }

    /// Runs `query` and shows its rows. The one path the form and the ADQL
    /// editor share, so a cancel or an error means the same in both.
    private func runQuery(_ query: String) async -> SearchOutcome {
        runningQuery?.cancel()
        let client = tapClient
        let task = Task { try await client.tapQueryRows(adql: query) }
        runningQuery = task
        isSearching = true
        searchStartedAt = Date()
        searchError = nil
        defer {
            // A newer search owns the spinner now.
            if runningQuery == task {
                runningQuery = nil
                isSearching = false
                searchStartedAt = nil
            }
        }
        do {
            let (headers, rows) = try await task.value
            try Task.checkCancellation()
            guard !task.isCancelled else { return .cancelled }
            resultsModel.loadResults(headers: headers, rows: rows, query: query, maxRec: TAPConfig.maxRecords)
            selectedTab = .results
            return .completed(rows: rows.count)
        } catch {
            if task.isCancelled || error is CancellationError { return .cancelled }
            let message = SearchError.describing(error)
            searchError = message
            return .failed(message)
        }
    }

    // MARK: - Quick search

    /// Column id → form-mutation action. Single source of truth for both
    /// which columns are quick-search-linkable *and* how their value maps
    /// onto form state. Adding a new quick-search column is one entry here;
    /// there is no second place to forget to update.
    private static let quickSearchActions: [String: @MainActor (SearchFormState, String) -> Void] = [
        "piname":     { state, value in state.piName = value },
        "proposalid": { state, value in state.proposalID = value },
        "targetname": { state, value in
            state.target = value
            // Keep the resolver active so coords can refine; if the user had
            // disabled the resolver entirely, restore the default service.
            if state.resolver == .none { state.resolver = .all }
        },
        "collection": { state, value in
            state.selectedCollections = [value]
            state.clearDataTrainCascade(after: 1)
        },
        "instrument": { state, value in
            state.selectedInstruments = [value]
            state.clearDataTrainCascade(after: 2)
        },
    ]

    /// Columns that can be turned into one-click "narrow by this value"
    /// quick-search links. Derived from ``quickSearchActions`` so the two
    /// can never drift out of sync.
    static var quickSearchableColumnIDs: Set<String> {
        Set(quickSearchActions.keys)
    }

    /// Called when the user clicks a quick-search-linked cell. Maps the
    /// column id to the corresponding form field via ``quickSearchActions``,
    /// overwrites just that field, and re-runs the search. Leaves unrelated
    /// form state alone so the user drills into the current search rather
    /// than starting from scratch.
    func quickSearch(columnID: String, rawValue: String) async {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let apply = Self.quickSearchActions[columnID] else { return }
        apply(formState, trimmed)
        await executeSearch()
    }

    // MARK: - Execute Raw ADQL

    /// Runs raw ADQL. `fromEditor` — the editor's Execute, by the person or
    /// an agent — keeps a completed query in Recent Searches; a saved query
    /// run from its list does not.
    @discardableResult
    func executeRawQuery(_ adql: String, fromEditor: Bool = false) async -> SearchOutcome {
        let attribution = takeAttribution()
        // What the checker is sure CADC would refuse is not sent — from the
        // editor, an assistant or a saved query alike (QA L13: LIMIT went out).
        let problems = ADQLValidator.problems(in: adql, schema: tapSchema.cached)
        guard problems.isEmpty else {
            searchError = problems.map(\.localizedSummary).joined(separator: "; ")
            return .refused(String(localized: "Not sent: \(problems.map(\.summary).joined(separator: "; "))"))
        }
        let outcome = await runQuery(adql)
        if fromEditor, case .completed = outcome {
            recentSearchStore.save(RecentSearch(
                name: RecentSearch.name(forQuery: adql), formSnapshot: SearchFormSnapshot(),
                agentAttribution: attribution, adql: adql))
        }
        return outcome
    }

    /// Puts a recent search back where it came from: an editor query into
    /// the editor, a form search into the form.
    func load(_ recent: RecentSearch) {
        if let adql = recent.adql {
            resultsModel.adqlQuery = adql
            searchError = nil
            selectedTab = .adql
        } else {
            loadFromSnapshot(recent.formSnapshot)
        }
    }

    /// Consumes the one-shot agent attribution and clears it unconditionally,
    /// so a failed search cannot leak the stamp onto a later user search.
    private func takeAttribution() -> AgentAttribution? {
        defer { nextSearchAttribution = nil }
        return nextSearchAttribution
    }

    // MARK: - Save Query

    func saveQuery(_ adql: String) {
        let name = "Query \u{2014} \(SharedFormatters.monthDayShortTime.string(from: Date()))"
        savedQueryStore.save(SavedQuery(name: name, adql: adql))
    }

    // MARK: - Load from Snapshot

    func loadFromSnapshot(_ snapshot: SearchFormSnapshot) {
        formState.loadFromSnapshot(snapshot)
        resolverStatus = .idle
        resolverResult = nil
        searchError = nil
        selectedTab = .search
        // Re-trigger target resolution if target is set
        if !formState.target.isEmpty && formState.resolver != .none {
            targetChanged()
        }
    }

    // MARK: - Reset

    func resetForm() {
        formState.reset()
        resolverStatus = .idle
        resolverResult = nil
        searchError = nil
    }
}
