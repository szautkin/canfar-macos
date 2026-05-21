// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

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
    private let resolverService: TargetResolverService

    // Target resolution state
    var resolverStatus: ResolverStatus = .idle
    var resolverResult: ResolverResult?

    // Search execution state
    var isSearching = false
    var searchError: String?

    // Tab state
    enum SearchTab: String, CaseIterable, Identifiable {
        case search, results, adql
        var id: String { rawValue }
    }
    var selectedTab: SearchTab = .search

    // Debounce task for target resolution
    private var resolveTask: Task<Void, Never>?

    // Stores are constructed inside the @MainActor init body so the
    // strict-concurrency check doesn't reject parameter defaults
    // evaluated in the caller's isolation context (the SwiftUI
    // @State property-wrapper init position isn't always inferred
    // MainActor at the syntactic call site).
    init(tapClient: TAPClient = TAPClient(),
         recentSearchStore: RecentSearchStore = RecentSearchStore(),
         savedQueryStore: SavedQueryStore? = nil) {
        self.tapClient = tapClient
        self.recentSearchStore = recentSearchStore
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

    // MARK: - Search (from form)

    func executeSearch() async {
        isSearching = true
        searchError = nil

        let resolverCoords: (ra: String, dec: String)?
        if let result = resolverResult, !result.coordsRA.isEmpty {
            resolverCoords = (ra: result.coordsRA, dec: result.coordsDec)
        } else {
            resolverCoords = nil
        }

        let query = ADQLBuilder.buildQuery(
            formState: formState,
            resolverCoords: resolverCoords
        )

        do {
            let (headers, rows) = try await tapClient.tapQueryRows(adql: query)
            resultsModel.loadResults(
                headers: headers,
                rows: rows,
                query: query,
                maxRec: TAPConfig.maxRecords
            )
            selectedTab = .results

            // Auto-save to recent searches
            let snapshot = formState.toSnapshot()
            if snapshot != SearchFormSnapshot() {
                let name = snapshot.autoName()
                recentSearchStore.save(RecentSearch(name: name, formSnapshot: snapshot))
            }
        } catch {
            searchError = error.localizedDescription
        }

        isSearching = false
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

    func executeRawQuery(_ adql: String) async {
        isSearching = true
        searchError = nil

        do {
            let (headers, rows) = try await tapClient.tapQueryRows(adql: adql)
            resultsModel.loadResults(
                headers: headers,
                rows: rows,
                query: adql,
                maxRec: TAPConfig.maxRecords
            )
            selectedTab = .results
        } catch {
            searchError = error.localizedDescription
        }

        isSearching = false
    }

    // MARK: - Save Query

    func saveQuery(_ adql: String) {
        let name = "Query \u{2014} \(formatDate(Date()))"
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

    // MARK: - Private

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}
