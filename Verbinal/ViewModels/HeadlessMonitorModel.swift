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

    /// The Batch Jobs sheet is showing: one owner, so an assistant opens it
    /// by its name as the card's button does (plan 30 T).
    var detailPresented = false

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
            history?.recordMissing(Self.firstSeenFinished(fetched, previous: previousStateMap))

            previousStateMap = transitions.current
            // Only what changed is set: whatever shows ten thousand jobs is not
            // redrawn for a poll that found them as they were.
            if fetched != jobs { jobs = fetched }
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
            // The delete returns once the platform lists the job as gone
            // or going (SessionService asks), so the list is current.
            try await headlessService.deleteJob(id: id)
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
        var running = 0, pending = 0, completed = 0, failed = 0
        for job in jobs {
            if job.isRunning { running += 1 } else if job.isPending { pending += 1 }
            else if job.isCompleted { completed += 1 } else if job.isFailed { failed += 1 }
        }
        // Set when changed, as the jobs are.
        if runningCount != running { runningCount = running }
        if pendingCount != pending { pendingCount = pending }
        if completedCount != completed { completedCount = completed }
        if failedCount != failed { failedCount = failed }
    }

    /// More ending at once than this are told in one notification: a sweep
    /// of a thousand jobs is one piece of news, not a thousand.
    nonisolated static let notifyEachUpTo = 3

    /// Says so, and writes it down: the notification is a moment, the
    /// record is what survives the platform reaping the job.
    private func announce(_ settled: [HeadlessJob]) {
        guard !settled.isEmpty else { return }
        if let summary = Self.endedTogether(settled) {
            NotificationService.sendJobsEnded(summary: summary, anyFailed: settled.contains(where: \.isFailed))
        } else {
            for job in settled {
                if job.isCompleted {
                    NotificationService.sendJobCompleted(sessionName: job.name, image: job.image)
                } else {
                    NotificationService.sendJobFailed(sessionName: job.name, image: job.image)
                }
            }
        }
        history?.record(settled.map { Self.record(of: $0) })
    }

    /// "12 done · 3 failed", for more than `notifyEachUpTo` ending at once;
    /// nil for fewer, each told by name.
    static func endedTogether(_ settled: [HeadlessJob]) -> String? {
        guard settled.count > notifyEachUpTo else { return nil }
        let done = settled.filter(\.isCompleted).count
        return [StatusCount(status: .done, count: done), StatusCount(status: .failed, count: settled.count - done)]
            .filter { $0.count > 0 }.map(\.text).joined(separator: " · ")
    }

    /// The jobs first seen already finished — ended while the app was
    /// closed, or between two polls — as the history keeps them: each once,
    /// the latest started first, no more than it holds. A job seen finished
    /// at the last poll was offered then.
    nonisolated static func firstSeenFinished(_ jobs: [HeadlessJob], previous: [String: String]?) -> [JobRecord] {
        jobs.filter { $0.isTerminal && previous?[$0.id] == nil }
            .sorted { $0.startedTime > $1.startedTime }
            .prefix(JobHistoryStore.maxJobs)
            .map { record(of: $0) }
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
