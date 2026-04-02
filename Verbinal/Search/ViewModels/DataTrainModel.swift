// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages the data train cascade logic with disk-cached data.
@Observable
@MainActor
final class DataTrainModel {
    private let dataTrainService: DataTrainService
    private var allRows: [DataTrainRow] = []
    private var didLoad = false

    var isLoading = false
    var isRefreshing = false
    var hasError = false
    var errorMessage = ""
    var lastRefreshed: Date?

    init(dataTrainService: DataTrainService) {
        self.dataTrainService = dataTrainService
    }

    /// Load data: returns cached data instantly if available, then background-refreshes if stale.
    /// Only loads once per app session unless explicitly refreshed.
    func loadData() async {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        hasError = false

        do {
            let (rows, wasCached) = try await dataTrainService.loadCachedOrFetch()
            allRows = rows
            lastRefreshed = await dataTrainService.cacheTimestamp()

            if wasCached {
                // Data loaded from cache — check if stale and refresh in background
                isLoading = false
                let stale = await dataTrainService.isCacheStale()
                if stale {
                    await silentRefresh()
                }
            } else {
                isLoading = false
            }
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Manual refresh triggered by user.
    func refreshData() async {
        isRefreshing = true
        hasError = false
        do {
            allRows = try await dataTrainService.fetchFresh()
            lastRefreshed = Date()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }

    /// Get filtered options for a specific data train column index.
    func filteredOptions(
        for columnIndex: Int,
        formState: SearchFormState
    ) -> [String] {
        let selections = currentSelections(formState)

        var filtered = allRows
        for i in 0..<columnIndex {
            let selected = selections[i]
            guard !selected.isEmpty else { continue }
            filtered = filtered.filter { row in
                guard let val = row.value(at: i) else { return false }
                return selected.contains(val)
            }
        }

        var seen = Set<String>()
        var options: [String] = []
        for row in filtered {
            if let val = row.value(at: columnIndex), !seen.contains(val) {
                seen.insert(val)
                options.append(val)
            }
        }

        return options.sorted()
    }

    /// Clear all downstream selections when an upstream column changes.
    func clearDownstream(from columnIndex: Int, formState: SearchFormState) {
        for i in (columnIndex + 1)..<ADQL.dataTrainColumns.count {
            setSelection([], for: i, formState: formState)
        }
    }

    /// Toggle a value in a data train column selection.
    func toggleValue(_ value: String, at columnIndex: Int, formState: SearchFormState) {
        var current = selection(for: columnIndex, formState: formState)
        if current.contains(value) {
            current.removeAll { $0 == value }
        } else {
            current.append(value)
        }
        setSelection(current, for: columnIndex, formState: formState)
        clearDownstream(from: columnIndex, formState: formState)
    }

    // MARK: - Private

    private func silentRefresh() async {
        isRefreshing = true
        do {
            allRows = try await dataTrainService.fetchFresh()
            lastRefreshed = Date()
        } catch {
            // Silent failure — stale cache is still usable
        }
        isRefreshing = false
    }

    private func currentSelections(_ formState: SearchFormState) -> [[String]] {
        [
            formState.selectedBands,
            formState.selectedCollections,
            formState.selectedInstruments,
            formState.selectedFilters,
            formState.selectedCalLevels,
            formState.selectedDataTypes,
            formState.selectedObsTypes,
        ]
    }

    private func selection(for columnIndex: Int, formState: SearchFormState) -> [String] {
        currentSelections(formState)[columnIndex]
    }

    private func setSelection(_ values: [String], for columnIndex: Int, formState: SearchFormState) {
        switch columnIndex {
        case 0: formState.selectedBands = values
        case 1: formState.selectedCollections = values
        case 2: formState.selectedInstruments = values
        case 3: formState.selectedFilters = values
        case 4: formState.selectedCalLevels = values
        case 5: formState.selectedDataTypes = values
        case 6: formState.selectedObsTypes = values
        default: break
        }
    }
}
