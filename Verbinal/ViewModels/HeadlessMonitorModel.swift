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
final class HeadlessMonitorModel: CadencedPoller {
    private let headlessService: HeadlessService

    var jobs: [HeadlessJob] = []
    var runningCount = 0
    var pendingCount = 0
    var completedCount = 0
    var failedCount = 0
    var totalActive: Int { runningCount + pendingCount }

    /// The Batch Jobs summary, every count, zeros too — an empty queue is
    /// not a view that has not loaded (plan 17 U2, QA N12).
    struct StatusCount: Equatable {
        enum Status: String { case running, pending, done, failed }
        let status: Status
        let count: Int
        var text: String {
            switch status {
            case .running: return String(localized: "\(count) running")
            case .pending: return String(localized: "\(count) pending")
            case .done: return String(localized: "\(count) done")
            case .failed: return String(localized: "\(count) failed")
            }
        }
    }

    var statusCounts: [StatusCount] {
        [.init(status: .running, count: runningCount), .init(status: .pending, count: pendingCount),
         .init(status: .done, count: completedCount), .init(status: .failed, count: failedCount)]
    }

    /// "0 running · 0 pending · 1 done · 1 failed".
    var statusSummary: String { statusCounts.map(\.text).joined(separator: " · ") }

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
    private(set) var cadence = PollCadence(watchCeiling: PollCadence.jobsWatchSeconds)
    /// Status by job id at the last poll; nil before the first.
    private var previousStateMap: [String: String]?

    /// Called when API returns 401 — signals that the token has expired.
    var onAuthFailure: (() -> Void)?

    /// Where finished jobs are remembered after the platform forgets them.
    let history: JobHistoryStore?

    init(headlessService: HeadlessService, history: JobHistoryStore? = nil) {
        self.headlessService = headlessService
        self.history = history
    }

    // MARK: - Data Loading

    func loadJobs() async {
        isLoading = true
        hasError = false
        errorMessage = ""

        do {
            let fetched = try await headlessService.getHeadlessJobs()
            let transitions = StatusTransitions(
                previous: previousStateMap,
                current: Dictionary(fetched.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last }))
            announce(transitions.newlySettled(
                fetched, id: \.id,
                wasInFlight: { !Self.isTerminalStatus($0) },
                isSettled: { $0.isCompleted || $0.isFailed }))

            // A job already finished when first seen — it ended while the
            // app was closed, or between polls on the first — is kept too.
            history?.recordMissing(fetched.filter(\.isTerminal).map { Self.record(of: $0) })

            previousStateMap = transitions.current
            jobs = fetched
            updateCounts()
            updateDockBadge()
            cadence.observe(inFlight: totalActive > 0, changed: transitions.changed)
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
        previousStateMap = nil
        cadence = PollCadence(watchCeiling: PollCadence.jobsWatchSeconds)
        pollTask = Task { [weak self] in
            await self?.loadJobs()
            guard let self, !Task.isCancelled else { return }
            self.pollTask = self.startPollLoop()
        }
    }

    func stopMonitoring() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
        pollCountdown = 0
        clearDockBadge()
    }

    func poll() async {
        await loadJobs()
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

    /// Says so, and writes it down: the notification is a moment, the
    /// record is what survives the platform reaping the job.
    private func announce(_ settled: [HeadlessJob]) {
        for job in settled {
            if job.isCompleted {
                NotificationService.sendJobCompleted(sessionName: job.name, image: job.image)
            } else {
                NotificationService.sendJobFailed(sessionName: job.name, image: job.image)
            }
            history?.record(Self.record(of: job))
        }
    }

    /// A settled job as the history keeps it. The platform's status is all
    /// there is to say why at this point; a probe's own record says more.
    nonisolated static func record(of job: HeadlessJob, at finished: Date = Date()) -> JobRecord {
        JobRecord(id: job.id, name: job.name, image: job.image, origin: .user,
                  outcome: job.isCompleted ? .succeeded : .failed, status: job.status, startedAt: job.startedTime,
                  finishedAt: finished, failureReason: job.isFailed ? job.status : nil, targetImage: nil)
    }

    private static func isTerminalStatus(_ status: String) -> Bool {
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
