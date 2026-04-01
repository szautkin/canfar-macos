// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

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
        do {
            try await headlessService.deleteJob(id: id)
            try? await Task.sleep(for: .seconds(3))
            await loadJobs()
        } catch {
            hasError = true
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func getLogs(id: String) async -> String? {
        try? await headlessService.getLogs(id: id)
    }

    func getEvents(id: String) async -> String? {
        try? await headlessService.getEvents(id: id)
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
