// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os
import VerbinalKit

/// The last few dozen compute runs, newest first, on disk — what the
/// Remote Compute screen shows and `list_compute_runs` answers from.
/// Before it, code an assistant ran on someone's account left no trace
/// they could find.
@Observable
@MainActor
final class ComputeRunStore {
    /// The code is kept with each run, so this also bounds the file.
    nonisolated static let maxRuns = 50

    private(set) var runs: [ComputeRun] = []

    private let persistence: DiskPersistence<[ComputeRun]>?

    init(persistence: DiskPersistence<[ComputeRun]>? = ComputeRunStore.productionPersistence) {
        self.persistence = persistence
        if case .value(let stored) = persistence?.readResult() { runs = stored }
    }

    nonisolated static let productionPersistence = DiskPersistence<[ComputeRun]>(
        subdirectory: "Verbinal", fileName: "compute_runs.json",
        logger: Logger(subsystem: "com.codebg.Verbinal", category: "ComputeRuns"))

    func find(_ id: String) -> ComputeRun? { runs.first { Self.same($0.id, id) } }

    /// Remembers a run just sent, at the top.
    func add(_ run: ComputeRun) {
        runs.removeAll { Self.same($0.id, run.id) }
        runs.insert(run, at: 0)
        runs = Array(runs.prefix(Self.maxRuns))
        save()
    }

    /// Records the watcher's result.
    func complete(_ id: String, with result: RunCodeContract.ResultFile) {
        update(id) { run in
            let status = result.status?.trimmingCharacters(in: .whitespaces).lowercased()
            run.status = status?.isEmpty == false ? status : "error"
            run.exitCode = result.exit_code
            run.durationMs = result.duration_ms
            run.finishedAt = result.finished_at.flatMap(SharedFormatters.isoDate) ?? run.finishedAt ?? Date()
        }
    }

    /// Closes a run still out with the app's own verdict (`noResult`, `notSent`).
    func close(_ id: String, as status: String) {
        update(id) { run in
            guard !run.isFinished else { return }
            run.status = status
            run.finishedAt = Date()
        }
    }

    func clear() {
        runs = []
        save()
    }

    /// Changes one run in place — its place is when it was sent. Reading the
    /// same result again changes nothing and writes nothing.
    private func update(_ id: String, _ change: (inout ComputeRun) -> Void) {
        guard let index = runs.firstIndex(where: { Self.same($0.id, id) }) else { return }
        var run = runs[index]
        change(&run)
        guard run != runs[index] else { return }
        runs[index] = run
        save()
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    private func save() {
        _ = persistence?.write(runs)
    }
}
