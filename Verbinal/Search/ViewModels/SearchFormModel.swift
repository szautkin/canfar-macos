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
    let recentSearchStore = RecentSearchStore()
    let savedQueryStore = SavedQueryStore()

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

    init() {
        let client = TAPClient()
        self.tapClient = client
        self.resolverService = TargetResolverService(tapClient: client)
        self.dataTrainModel = DataTrainModel(
            dataTrainService: DataTrainService(tapClient: client)
        )
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
