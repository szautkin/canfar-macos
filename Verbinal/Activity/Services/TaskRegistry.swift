// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// What the app is doing, in one place.
///
/// Each slow operation used to give whatever feedback its control offered —
/// a row subtitle, a status line, often nothing — so a probe three minutes
/// into waiting on a job and one that failed to submit looked the same from
/// outside, and like nothing at all once its sheet was closed. One registry,
/// a stage rather than a flag, and an outcome recorded even when nobody
/// reports one: "running forever" is not a state reachable by omission.
///
/// Shared by default (`shared`), as a cross-cutting log is; each user takes
/// it as a parameter, so a test hands in its own.
@Observable
@MainActor
final class TaskRegistry {
    nonisolated static let shared = TaskRegistry()

    nonisolated init() {}

    /// Finished tasks are kept so a failure can be read after the fact —
    /// bounded, so a sweep of three hundred probes cannot grow it forever.
    nonisolated static let maxTasks = 60

    /// Oldest first.
    private(set) var tasks: [TrackedTask] = []
    private var nextID = 0

    /// Starts tracking work; the handle owns its outcome. Who started it is
    /// the task's initiator unless the caller knows better; why is its
    /// cause's, or `why` — the rule, when the app starts work of its own
    /// (plan 23 K).
    func begin(_ kind: TaskKind, _ label: String, by initiator: Initiator = Initiator.current,
               why: String? = nil, cause: Cause = Cause.current) -> TaskHandle {
        nextID += 1
        let again = tasks.contains { $0.label == label && $0.progress == .failed }
        var cause = cause
        if let why { cause.why = Cause.clip(why) }
        tasks.append(TrackedTask(id: nextID, kind: kind, label: label, startedBy: initiator, cause: cause,
                                 isAgain: again, started: Date()))
        // The oldest FINISHED go first: running work is what a reader most
        // needs to see, and is never dropped to make room.
        while tasks.count > Self.maxTasks, let finished = tasks.firstIndex(where: \.isFinished) {
            tasks.remove(at: finished)
        }
        return TaskHandle(id: nextID, registry: self)
    }

    /// Runs `work` as a task, from any actor: succeeded when it returns,
    /// failed with its error's words when it throws, abandoned when cancelled.
    /// `by` defaults to the caller's initiator; work run in a detached task,
    /// which drops it, passes the one it captured (plan 19 T2).
    nonisolated func track<T: Sendable>(_ kind: TaskKind, _ label: String, by initiator: Initiator = Initiator.current,
                                        why: String? = nil,
                                        _ work: @Sendable (TaskHandle) async throws -> T) async rethrows -> T {
        var cause = Cause.current
        if let why { cause.why = Cause.clip(why) }
        let handle = await begin(kind, label, by: initiator, cause: cause)
        // The work runs under the task's cause, and knows its task, so what it
        // records says why and where (plan 23).
        cause.task = handle.id
        do {
            let result = try await Cause.$current.withValue(cause) { try await work(handle) }
            await handle.succeed()
            return result
        } catch {
            if error is CancellationError { await handle.abandon() } else { await handle.fail(error.localizedDescription) }
            throw error
        }
    }

    var runningCount: Int { tasks.filter { !$0.isFinished }.count }
    var failedCount: Int { tasks.filter(\.wentWrong).count }

    /// Forgets what has finished, leaving what is running.
    func clearFinished() {
        tasks.removeAll(where: \.isFinished)
    }

    fileprivate func setStage(_ id: Int, _ stage: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isFinished else { return }
        tasks[index].stage = stage
    }

    /// The first outcome wins: a task finished explicitly is not rewritten.
    fileprivate func finish(_ id: Int, _ progress: TaskProgress, _ message: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isFinished else { return }
        tasks[index].progress = progress
        tasks[index].message = message
        // Where it had got to is over; how it ended is the message (QA L10).
        tasks[index].stage = ""
        tasks[index].finished = Date()
    }
}

/// A running task. Say how it ended — or letting go of the handle records
/// that nobody did: an early return, a thrown error, a closed sheet read as
/// "abandoned", never as running for the rest of the session.
@MainActor
final class TaskHandle {
    /// The task's id on the bar.
    let id: Int
    private weak var registry: TaskRegistry?
    private var finished = false

    fileprivate init(id: Int, registry: TaskRegistry) {
        self.id = id
        self.registry = registry
    }

    deinit {
        guard !finished, let registry else { return }
        let id = id
        Task { @MainActor in registry.finish(id, .cancelled, nil) }
    }

    /// Where the work has got to.
    func stage(_ stage: String) { registry?.setStage(id, stage) }

    /// Runs `work` as this task's: what it records knows its task (plan 23).
    /// `track` does this itself; work begun with `begin` asks.
    func within<T>(_ work: () async throws -> T) async rethrows -> T {
        var cause = Cause.current
        cause.task = id
        return try await Cause.$current.withValue(cause) { try await work() }
    }

    func succeed(_ note: String? = nil) { complete(.succeeded, note) }

    /// It did not work, and this is why.
    func fail(_ why: String) { complete(.failed, why) }

    /// It was given up on.
    func abandon() { complete(.cancelled, nil) }

    private func complete(_ progress: TaskProgress, _ message: String?) {
        guard !finished else { return }
        finished = true
        registry?.finish(id, progress, message)
    }
}
