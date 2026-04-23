// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages the data-train cascade with disk-cached data.
///
/// Concurrency: ``loadData()`` is idempotent and race-safe — the very first
/// call kicks off the fetch task and stores its handle in `loadTask`; any
/// subsequent call before completion awaits the same task rather than either
/// racing a second fetch or returning early while rows are still empty.
@Observable
@MainActor
final class DataTrainModel {
    private let dataTrainService: DataTrainService
    private var allRows: [DataTrainRow] = []

    /// Single-flight handle for any in-flight load or refresh. Both
    /// ``loadData()`` and ``refreshData()`` install themselves here so a
    /// concurrent call always *joins* the in-flight operation rather than
    /// starting a second fetch. Without this discipline, a refresh-triggered
    /// cancel + reset to nil would open a race window where a simultaneous
    /// `loadData()` kicks off a parallel performLoad against the service.
    private var inFlightTask: Task<Void, Never>?

    var isLoading = false
    var isRefreshing = false
    var hasError = false
    var errorMessage = ""
    var lastRefreshed: Date?

    init(dataTrainService: DataTrainService) {
        self.dataTrainService = dataTrainService
    }

    /// Load data once per session: returns cached data instantly if available,
    /// then background-refreshes if stale. Concurrent callers share the task.
    func loadData() async {
        if let inFlightTask {
            await inFlightTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        inFlightTask = task
        await task.value
    }

    /// Manual refresh — cancels any in-flight load and installs the refresh
    /// as the new in-flight task so a concurrent `loadData()` awaits it
    /// rather than forking a parallel fetch.
    func refreshData() async {
        inFlightTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        inFlightTask = task
        await task.value
    }

    // MARK: - Cascade reads

    /// Get filtered options for a specific data-train column index.
    /// Upstream selections narrow the candidate set; the returned options are
    /// deduped and sorted alphabetically.
    func filteredOptions(
        for columnIndex: Int,
        formState: SearchFormState
    ) -> [String] {
        let selections = currentSelections(formState)
        guard columnIndex >= 0, columnIndex < selections.count else { return [] }

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

    // MARK: - Cascade mutations

    /// Toggle a value in a data-train column and reset all downstream selections.
    func toggleValue(_ value: String, at columnIndex: Int, formState: SearchFormState) {
        var current = selection(for: columnIndex, formState: formState)
        if current.contains(value) {
            current.removeAll { $0 == value }
        } else {
            current.append(value)
        }
        setSelection(current, for: columnIndex, formState: formState)
        formState.clearDataTrainCascade(after: columnIndex)
    }

    /// Clear downstream selections. Retained for callers that need an explicit
    /// reset without a toggle.
    func clearDownstream(from columnIndex: Int, formState: SearchFormState) {
        formState.clearDataTrainCascade(after: columnIndex)
    }

    // MARK: - Private

    private func performLoad() async {
        isLoading = true
        hasError = false

        do {
            let (rows, wasCached) = try await dataTrainService.loadCachedOrFetch()
            allRows = rows
            lastRefreshed = await dataTrainService.cacheTimestamp()

            if wasCached {
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

    /// User-triggered refresh — surfaces errors in the UI.
    private func performRefresh() async {
        isRefreshing = true
        hasError = false
        do {
            let fresh = try await dataTrainService.fetchFresh()
            allRows = fresh
            lastRefreshed = Date()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }

    /// Background stale-cache refresh — failure is silent, because the stale
    /// cache is still usable and the user didn't ask for this.
    private func silentRefresh() async {
        isRefreshing = true
        do {
            let fresh = try await dataTrainService.fetchFresh()
            allRows = fresh
            lastRefreshed = Date()
        } catch {
            // Silent failure — stale cache is still usable.
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
        let all = currentSelections(formState)
        guard columnIndex >= 0, columnIndex < all.count else { return [] }
        return all[columnIndex]
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
