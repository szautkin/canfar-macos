// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

@Observable
@MainActor
final class HeadlessMonitorModel {
    private let headlessService: HeadlessService

    var jobs: [HeadlessJob] = []
    var runningCount = 0
    var pendingCount = 0
    var completedCount = 0
    var failedCount = 0
    var totalActive: Int { runningCount + pendingCount }

    var isLoading = false
    var isPolling = false
    var pollCountdown = 0
    var hasError = false
    var errorMessage = ""

    /// Job ids the user has clicked Delete on but the service
    /// hasn't yet acknowledged. Rows in the detail sheet read
    /// this to swap the trash icon for an in-flight indicator
    /// while the request is round-tripping to Skaha. 2026-05-19
    /// addition: closes the "no clear icon to delete a job"
    /// UX gap — the trash icon needs an in-flight state so the
    /// user doesn't double-click while the first delete is in
    /// flight.
    var deletingJobIDs: Set<String> = []

    private var pollTask: Task<Void, Never>?
    private let pollInterval = 45
    private var previousStateMap: [String: String] = [:]
    private var isFirstPoll = true

    /// Called when API returns 401 — signals that the token has expired.
    var onAuthFailure: (() -> Void)?

    init(headlessService: HeadlessService) {
        self.headlessService = headlessService
    }

    // MARK: - Data Loading

    func loadJobs() async {
        isLoading = true
        hasError = false
        errorMessage = ""

        do {
            let fetched = try await headlessService.getHeadlessJobs()
            let newStateMap = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0.status) })

            if !isFirstPoll {
                detectTransitions(from: previousStateMap, to: newStateMap, jobs: fetched)
            }

            previousStateMap = newStateMap
            isFirstPoll = false
            jobs = fetched
            updateCounts()
            updateDockBadge()
        } catch let error as NetworkError where error.isUnauthorized {
            hasError = true
            errorMessage = error.localizedDescription
            stopMonitoring()
            onAuthFailure?()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Polling

    func startMonitoring() {
        guard !isPolling else { return }
        isPolling = true
        isFirstPoll = true
        previousStateMap = [:]
        pollTask = Task { [weak self] in
            await self?.loadJobs()
            await self?.pollLoop()
        }
    }

    func stopMonitoring() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
        pollCountdown = 0
        clearDockBadge()
    }

    private func pollLoop() async {
        while !Task.isCancelled && isPolling {
            pollCountdown = pollInterval

            for _ in 0..<pollInterval {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
                pollCountdown -= 1
            }

            if Task.isCancelled { return }
            await loadJobs()
        }
    }

    // MARK: - Job Actions

    func deleteJob(id: String) async {
        // Mark in-flight so the UI swaps the trash icon for the
        // pulsing in-flight indicator and disables further taps
        // on this row until the round-trip completes.
        deletingJobIDs.insert(id)
        defer { deletingJobIDs.remove(id) }
        do {
            try await headlessService.deleteJob(id: id)
            // Skaha returns from DELETE before the underlying K8s
            // pod is fully gone. The 3s pause matches the average
            // Skaha→K8s propagation delay; without it, the
            // immediate `loadJobs()` would still show the job in
            // the list and the user perceives the delete as
            // not-working.
            try? await Task.sleep(for: .seconds(3))
            await loadJobs()
        } catch {
            hasError = true
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Fetches job logs. Returns `.failure` (with the underlying error)
    /// instead of swallowing it, so callers can distinguish a real fetch
    /// failure (auth/network/missing endpoint) from a successful empty result.
    func getLogs(id: String) async -> Result<String, Error> {
        do {
            return .success(try await headlessService.getLogs(id: id))
        } catch {
            return .failure(error)
        }
    }

    /// Fetches job events. See `getLogs` for failure semantics.
    func getEvents(id: String) async -> Result<String, Error> {
        do {
            return .success(try await headlessService.getEvents(id: id))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Private

    private func updateCounts() {
        runningCount = jobs.filter { $0.isRunning }.count
        pendingCount = jobs.filter { $0.isPending }.count
        completedCount = jobs.filter { $0.isCompleted }.count
        failedCount = jobs.filter { $0.isFailed }.count
    }

    private func detectTransitions(from old: [String: String], to new: [String: String], jobs: [HeadlessJob]) {
        for job in jobs {
            guard let oldStatus = old[job.id] else { continue }
            if isTerminalStatus(oldStatus) { continue }

            if job.isCompleted {
                NotificationService.sendJobCompleted(sessionName: job.name, image: job.image)
            } else if job.isFailed {
                NotificationService.sendJobFailed(sessionName: job.name, image: job.image)
            }
        }
    }

    private func isTerminalStatus(_ status: String) -> Bool {
        let lower = status.lowercased()
        return lower == "completed" || lower == "succeeded" || lower == "failed" || lower == "error"
    }

    private func updateDockBadge() {
        PlatformBadge.set(totalActive)
    }

    private func clearDockBadge() {
        PlatformBadge.clear()
    }
}
