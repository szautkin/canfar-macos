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
    /// Each task as it begins, is paused or resumed, and ends — for the
    /// session log (plan 23).
    nonisolated let events = Observers<TrackedTask>()

    /// What pausing a task does, given by its owner when it begins (plan 40):
    /// stop where it is, and go on. Each is told who asked.
    struct Pausing {
        let pause: @MainActor (Initiator) -> Void
        let resume: @MainActor (Initiator) -> Void
    }
    private var pausing: [Int: Pausing] = [:]

    /// What trying a failed task again does, given by its owner (plan 44 E):
    /// the bar's Retry. `byAssistant`: retry_activity may too — a sync, which
    /// moves only what the person chose; a transfer is the person's again,
    /// or its tool's.
    struct Retrying {
        let byAssistant: Bool
        let retry: @MainActor (Initiator) -> Void
    }
    private var retrying: [Int: Retrying] = [:]

    /// A count changes the bar at most this often: work that counts fast
    /// must not redraw it for every item.
    nonisolated static let countInterval: TimeInterval = 0.25
    private var counted: [Int: Date] = [:]
    private var pendingCount: [Int: (done: Int, total: Int?)] = [:]

    /// Starts tracking work; the handle owns its outcome. Who started it is
    /// the task's initiator unless the caller knows better; why is its
    /// cause's, or `why` — the rule, when the app starts work of its own
    /// (plan 23 K).
    /// Work its owner can pause gives `pausing`; work that begins paused —
    /// paused before, and still — says by whom (`pausedBy`).
    func begin(_ kind: TaskKind, _ label: String, by initiator: Initiator = Initiator.current,
               why: String? = nil, cause: Cause = Cause.current,
               pausing: Pausing? = nil, pausedBy: PauseMark? = nil) -> TaskHandle {
        nextID += 1
        let again = tasks.contains { $0.label == label && $0.progress == .failed }
        var cause = cause
        if let why { cause.why = Cause.clip(why) }
        var task = TrackedTask(id: nextID, kind: kind, label: label, startedBy: initiator, cause: cause,
                               isAgain: again, started: Date())
        task.canPause = pausing != nil
        if let pausing { self.pausing[nextID] = pausing }
        if let pausedBy {
            task.progress = .paused
            task.pause = pausedBy
        }
        tasks.append(task)
        events.notify(task)
        // The oldest FINISHED go first: running work is what a reader most
        // needs to see, and is never dropped to make room.
        while tasks.count > Self.maxTasks, let finished = tasks.firstIndex(where: \.isFinished) {
            retrying[tasks.remove(at: finished).id] = nil
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

    var runningCount: Int { tasks.filter { $0.progress == .running }.count }
    var pausedCount: Int { tasks.filter(\.isPaused).count }
    var failedCount: Int { tasks.filter(\.wentWrong).count }

    func task(_ id: Int) -> TrackedTask? { tasks.first { $0.id == id } }

    /// What pausing task `id` does, while it can be paused.
    func pausing(_ id: Int) -> Pausing? { pausing[id] }

    // MARK: - Pausing (plan 40)

    /// Pauses task `id` for `initiator`, with why: its owner stops it where
    /// it is. Nil when it is paused; otherwise why not, in words.
    func pause(_ id: Int, by initiator: Initiator, why: String? = nil) -> String? {
        switch pausable(id) {
        case .refused(let reason): return reason
        case .at(let index):
            guard !tasks[index].isPaused else { return nil }
            flushCount(id)
            mark(index, paused: true, by: initiator, why: why)
            pausing[id]?.pause(initiator)
            return nil
        }
    }

    /// Resumes task `id` for `initiator`: its owner goes on from where it
    /// stopped. Nil when it runs; otherwise why not, in words.
    func resume(_ id: Int, by initiator: Initiator, why: String? = nil) -> String? {
        switch pausable(id) {
        case .refused(let reason): return reason
        case .at(let index):
            guard tasks[index].isPaused else { return nil }
            mark(index, paused: false, by: initiator, why: why)
            pausing[id]?.resume(initiator)
            return nil
        }
    }

    // MARK: - Retrying (plan 44 E)

    fileprivate func offerRetry(_ id: Int, _ offer: Retrying) {
        retrying[id] = offer
    }

    /// Tries failed task `id` again for `initiator`, as its owner says: the
    /// bar's Retry, or retry_activity. Nil when it went; otherwise why not.
    func retry(_ id: Int, by initiator: Initiator) -> String? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return "There is no task \(id) on the activity bar; list_activity gives each one's id."
        }
        let task = tasks[index]
        guard task.progress == .failed, let offer = retrying[id] else {
            return "\(task.label) cannot be tried again from the bar."
        }
        guard initiator == .person || offer.byAssistant else {
            return "\(task.label) is the person's to try again (Retry on the activity bar), or its tool's: call it again."
        }
        retrying[id] = nil
        tasks[index].canRetry = false
        offer.retry(initiator)
        return nil
    }

    /// A task that can be paused or resumed now, or why not.
    private enum Pausable { case at(Int), refused(String) }

    private func pausable(_ id: Int) -> Pausable {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return .refused("There is no task \(id) on the activity bar; list_activity gives each one's id.")
        }
        let task = tasks[index]
        guard !task.isFinished else { return .refused("\(task.label) has finished (\(task.progress.rawValue)).") }
        guard task.canPause, pausing[id] != nil else { return .refused("\(task.label) cannot be paused.") }
        return .at(index)
    }

    private func mark(_ index: Int, paused: Bool, by initiator: Initiator, why: String?) {
        var cause = Cause.current
        if let why { cause.why = Cause.clip(why) }
        tasks[index].progress = paused ? .paused : .running
        tasks[index].pause = PauseMark(by: initiator, cause: cause, at: Date(), resumed: !paused)
        events.notify(tasks[index])
    }

    // MARK: - Counting (plan 40)

    fileprivate func setCount(_ id: Int, _ done: Int, _ total: Int?) {
        guard tasks.contains(where: { $0.id == id && !$0.isFinished }) else { return }
        if let last = counted[id], Date().timeIntervalSince(last) < Self.countInterval, done != total {
            if pendingCount.updateValue((done, total), forKey: id) == nil {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.countInterval))
                    self?.flushCount(id)
                }
            }
            return
        }
        pendingCount[id] = nil
        applyCount(id, done, total)
    }

    private func flushCount(_ id: Int) {
        guard let pending = pendingCount.removeValue(forKey: id) else { return }
        applyCount(id, pending.done, pending.total)
    }

    private func applyCount(_ id: Int, _ done: Int, _ total: Int?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isFinished else { return }
        tasks[index].done = done
        tasks[index].total = total
        counted[id] = Date()
    }

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
        flushCount(id)
        pausing[id] = nil
        counted[id] = nil
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isFinished else { return }
        tasks[index].progress = progress
        tasks[index].message = message
        // Only a failure is tried again.
        if progress == .failed { tasks[index].canRetry = retrying[id] != nil } else { retrying[id] = nil }
        // Where it had got to is over; how it ended is the message (QA L10).
        tasks[index].stage = ""
        tasks[index].finished = Date()
        events.notify(tasks[index])
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

    /// How far it has got: `done` of `total`, nil while the total is not
    /// known (plan 40). The bar shows it at most four times a second.
    func count(_ done: Int, of total: Int?) { registry?.setCount(id, done, total) }

    /// Whether someone has paused it.
    var isPaused: Bool { registry?.task(id)?.isPaused ?? false }

    /// Should it fail, what trying it again does: the bar offers Retry
    /// (plan 44 E). `byAssistant`: retry_activity may too.
    func offerRetry(byAssistant: Bool = false, _ retry: @escaping @MainActor (Initiator) -> Void) {
        registry?.offerRetry(id, .init(byAssistant: byAssistant, retry: retry))
    }

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
