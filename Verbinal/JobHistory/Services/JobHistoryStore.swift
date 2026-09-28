// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os
import VerbinalKit

/// The last few dozen finished batch jobs, newest first, on disk — the
/// Batch Jobs sheet's History, and `list_job_history`.
@Observable
@MainActor
final class JobHistoryStore {
    /// Enough that a morning of failed probes does not push the
    /// interesting one off the end; small enough for a few tens of KB.
    nonisolated static let maxJobs = 50

    private(set) var jobs: [JobRecord] = []

    private let persistence: DiskPersistence<[JobRecord]>?

    init(persistence: DiskPersistence<[JobRecord]>? = JobHistoryStore.productionPersistence) {
        self.persistence = persistence
        if case .value(let stored) = persistence?.readResult() { jobs = stored }
    }

    nonisolated static let productionPersistence = DiskPersistence<[JobRecord]>(
        subdirectory: "Verbinal", fileName: "job_history.json",
        logger: Logger(subsystem: "com.codebg.Verbinal", category: "JobHistory"))

    /// Remembers a finished job at the top, merged with any earlier record
    /// of it — the one that carries the reason must not be lost.
    func record(_ job: JobRecord) {
        guard !job.id.isEmpty else { return }
        let earlier = jobs.first { $0.id == job.id }
        jobs.removeAll { $0.id == job.id }
        jobs.insert(earlier.map(job.keeping) ?? job, at: 0)
        jobs = Array(jobs.prefix(Self.maxJobs))
        save()
    }

    /// Remembers the jobs it has no record of, each in its place by when it
    /// finished — a job seen already finished, or a failure from before the
    /// history was kept. A job it knows is left as it is.
    func recordMissing(_ found: [JobRecord]) {
        let known = Set(jobs.map(\.id))
        var seen = Set<String>()
        let missing = found.filter { !$0.id.isEmpty && !known.contains($0.id) && seen.insert($0.id).inserted }
        guard !missing.isEmpty else { return }
        jobs = Array((jobs + missing).sorted { $0.finishedAt > $1.finishedAt }.prefix(Self.maxJobs))
        save()
    }

    /// `recordMissing`, once per `key` on this Mac: a clean-up that must not
    /// come back after the person clears the history.
    func recordMissingOnce(_ found: [JobRecord], key: String, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key) else { return }
        recordMissing(found)
        defaults.set(true, forKey: key)
    }

    func clear() {
        jobs = []
        save()
    }

    private func save() {
        _ = persistence?.write(jobs)
    }
}
