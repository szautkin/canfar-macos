// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import Observation
import VerbinalKit

/// One collection of the person's work, as its area gives it to the sync
/// (plan 36 3.1): its kind, and what to watch for its changes.
struct WorkCollection {
    let kind: any StorageKind
    /// Reads what changes when the collection does, for observation.
    let watch: @MainActor () -> Void
}

/// The storage sync as the app runs it (plan 34 V): at once after sign-in,
/// in the background and unseen; again when Verbinal comes back to the
/// front and the last sync is over 15 minutes old; a few seconds after a
/// collection the person keeps in VOSpace changes; and when asked. Nothing
/// after sign-out, and nothing for an account without CANFAR storage.
/// Settings ▸ Storage and the tools read its status.
@Observable
@MainActor
final class StorageSyncModel {
    /// What the sync is given of the app, at sign-in.
    struct Dependencies {
        let vospace: VOSpaceBrowserService
        /// The person's work, each collection from its area.
        let work: [WorkCollection]
        let importManifest: @Sendable (Data) async -> Bool
        let resumeRuns: @Sendable () async -> Void
    }

    /// As the sync last said it. Set here; a test sets it to show a state.
    var status: StorageSync.Status? {
        didSet {
            ResultDestination.shared.keeping = keeps("results")
            showPausedFromBefore()
        }
    }
    /// The kind syncing now, and how far it has got, as the sync says it.
    private(set) var current: StorageSync.Progress?

    /// The sync on the activity bar, while it moves enough to watch or is
    /// paused (plan 40).
    private var task: TaskHandle?
    private let tasks: TaskRegistry
    /// Each sign-in's sync is numbered: what a stopped one still says — its
    /// last run ending after a sign-out — is not this one's (plan 40).
    private var generation = 0
    /// A sync that moves fewer items than this is not on the bar: a note
    /// sent five seconds after it was written would fill the list with
    /// lines. Settings ▸ Storage and list_storage_kinds say it all the same.
    static let showFrom = 5

    init(tasks: TaskRegistry = .shared) {
        self.tasks = tasks
    }
    /// Why the last change of the person's failed.
    private(set) var problem: String?
    private var sync: StorageSync?
    private var work: [WorkCollection] = []
    private var changed: [String: Task<Void, Never>] = [:]
    private var activation: NSObjectProtocol?
    private static let comeBackAfter: TimeInterval = 15 * 60
    private static let changeSettles: Duration = .seconds(5)

    // MARK: When VOSpace is slow or out of service (plan 44 E)

    /// After a failure, the wait before the next try: 1, 2, 4 … 30 minutes.
    /// A test shortens it.
    var retryWait: (_ failuresInARow: Int) -> TimeInterval = { failures in
        min(30 * 60, 60 * pow(2, Double(max(0, failures - 1))))
    }
    /// A sync waiting longer than this is on the bar, whatever it moves.
    var slowAfter: Duration = .seconds(10)
    /// Failed syncs in a row, since the last that went.
    private var failuresInARow = 0
    /// When the next try is, while one waits after a failure.
    private(set) var nextTry: Date?
    private var retry: Task<Void, Never>?
    private var slow: Task<Void, Never>?
    /// The last failed sync on the bar: only it offers Retry.
    private var failedTask: Int?
    private var watchingNetwork = false

    /// Whether the person keeps collection `id` in VOSpace — their choice,
    /// one collection at a time (plan 36 3.2), declared in the manifest so
    /// every device makes the same.
    func keeps(_ id: String) -> Bool {
        chosen[id]?.keep ?? status?.kinds.first { $0.id == id }?.declared ?? false
    }

    /// What the person just chose, while it is written (plan 44): the switch
    /// shows it at once — it waited for the collection's first sync, and
    /// snapped back meanwhile. Numbered, so an earlier choice's end does not
    /// take back a later one.
    private var chosen: [String: (keep: Bool, number: Int)] = [:]
    private var choices = 0

    /// False for an account without CANFAR storage: nothing is synced.
    var hasStorage: Bool? { status?.hasStorage }

    /// The kinds this build knows, given what each needs of the app.
    static func catalog(_ deps: Dependencies) -> StorageKindCatalog {
        StorageKindCatalog(kinds: deps.work.map(\.kind) + [
            ImagePackagesKind(importManifest: deps.importManifest),
            ComputeRunsKind(resume: deps.resumeRuns),
            CountedKind.stagedScripts,
            CountedKind.exports,
        ])
    }

    func signedIn(username: String, _ deps: Dependencies) {
        signedOut()
        generation += 1
        let mine = generation
        let remote = RetryingStorageRemote(base: VOSpaceStorageRemote(vospace: deps.vospace, username: username))
        let sync = StorageSync(remote: remote,
                               catalog: Self.catalog(deps), stateFile: StorageSyncState.file(for: username),
                               watcher: { [weak self] event in await self?.heard(event, from: mine) })
        self.sync = sync
        work = deps.work
        let vospace = deps.vospace
        ResultDestination.shared.send = { file, folder in
            try await ResultUpload(vospace: vospace, username: username).upload(file, to: folder)
        }
        run(.signedIn)
        for collection in work { watch(collection) }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
    }

    /// A sync of a test's own, for the switches.
    func attach(_ sync: StorageSync) {
        self.sync = sync
    }

    func signedOut() {
        generation += 1
        chosen = [:]
        retry?.cancel()
        retry = nil
        slow?.cancel()
        slow = nil
        failuresInARow = 0
        nextTry = nil
        changed.values.forEach { $0.cancel() }
        changed = [:]
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        ResultDestination.shared.send = nil
        let stopping = sync
        Task { await stopping?.stop() }
        sync = nil
        status = nil
        current = nil
        work = []
        task?.abandon()
        task = nil
    }

    // MARK: - On the activity bar (plan 40)

    /// The task's id on the bar, for the tools.
    var taskID: Int? { task?.id }

    var isPaused: Bool { status?.paused != nil || (task.map { tasks.task($0.id)?.isPaused == true } ?? false) }

    /// Pauses the sync where it is — Settings ▸ Storage's Pause, or the
    /// bar's, through the registry.
    func pause(by initiator: Initiator = .person) {
        if let task {
            _ = tasks.pause(task.id, by: initiator)
            return
        }
        task = beginTask(pausedBy: PauseMark(by: initiator, cause: Cause(), at: Date(), resumed: false))
        pauseSync(by: initiator)
    }

    /// Resumes it: it goes on from where it stopped.
    func resume(by initiator: Initiator = .person) {
        if let task, tasks.task(task.id)?.isPaused == true {
            _ = tasks.resume(task.id, by: initiator)
            return
        }
        resumeSync()
    }

    private func beginTask(pausedBy: PauseMark?) -> TaskHandle {
        tasks.begin(.storage, String(localized: "Syncing with your storage"), by: .app,
                    why: "the storage sync: what another device kept comes to this Mac, and this Mac's changes go",
                    pausing: .init(pause: { [weak self] by in self?.pauseSync(by: by) },
                                   resume: { [weak self] _ in self?.resumeSync() }),
                    pausedBy: pausedBy)
    }

    /// The registry marked it paused: the sync stops after the item under
    /// way, keeping who and why.
    private func pauseSync(by initiator: Initiator) {
        guard let sync else { return }
        let why = task.flatMap { tasks.task($0.id)?.pause?.cause.why }
        let mine = generation
        Task { [weak self] in
            await sync.pause(by: initiator, why: why)
            self?.update(await sync.status(), from: mine)
        }
    }

    private func resumeSync() {
        guard let sync else { return }
        Task { [weak self] in
            await sync.resume()
            self?.run(.asked)
        }
    }

    /// Paused before — on this Mac, before a relaunch or a sign-in — and
    /// still: on the bar, where the person and assistants resume it.
    private func showPausedFromBefore() {
        guard task == nil, let paused = status?.paused else { return }
        let by = Initiator(rawValue: paused.by) ?? .person
        task = beginTask(pausedBy: PauseMark(by: by, cause: Cause(why: paused.why), at: paused.at, resumed: false))
        if let kind = paused.kind { task?.stage(StorageSettingsTab.title(kind)) }
        if let done = paused.done { task?.count(done, of: paused.total) }
    }

    /// What the sync says as it goes; a stopped sync's words are not heard.
    func heard(_ event: StorageSync.Event, from sync: Int? = nil) {
        guard sync.map({ $0 == generation }) ?? true else { return }
        switch event {
        case .began:
            // Slow, whatever it moves: on the bar after a while (plan 44 E5).
            slow?.cancel()
            let after = slowAfter
            slow = Task { [weak self] in
                try? await Task.sleep(for: after)
                guard !Task.isCancelled, let self, self.task == nil else { return }
                self.task = self.beginTask(pausedBy: nil)
                self.task?.stage(String(localized: "Waiting for your CANFAR storage…"))
            }
        case .progress(let count):
            current = count
            if task == nil, count.total >= Self.showFrom { task = beginTask(pausedBy: nil) }
            task?.stage(StorageSettingsTab.title(count.kind))
            task?.count(count.done, of: count.total)
        case .ended(let imported, let sent, let failure, let paused, let found, let toChoose):
            current = nil
            slow?.cancel()
            slow = nil
            guard !paused else { return }
            if let failure {
                // On the bar whatever it moved, with Retry and the next try
                // (plan 44 E1, E2): it was told only in Settings.
                failuresInARow += 1
                let wait = retryWait(failuresInARow)
                nextTry = Date().addingTimeInterval(wait)
                let failed = task ?? beginTask(pausedBy: nil)
                failed.offerRetry(byAssistant: true) { [weak self] _ in self?.retryNow() }
                failed.fail(Self.failed(failure, retryingIn: wait))
                failedTask.map(tasks.withdrawRetry)
                failedTask = failed.id
                task = nil
                scheduleRetry(after: wait)
            } else {
                failuresInARow = 0
                nextTry = nil
                retry?.cancel()
                retry = nil
                failedTask.map(tasks.withdrawRetry)
                failedTask = nil
                let moved = Self.moved(imported: imported, sent: sent)
                if found > 0 {
                    // Something for the person to choose: on the bar, whatever
                    // it moved (plan 45).
                    (task ?? beginTask(pausedBy: nil)).succeed(moved + " · " + Self.toChoose(toChoose))
                } else {
                    task?.succeed(moved)
                }
                task = nil
            }
        }
    }

    /// A failure, and when Verbinal tries again.
    static func failed(_ why: String, retryingIn wait: TimeInterval) -> String {
        let minutes = max(1, Int((wait / 60).rounded()))
        return String(localized: "\(why) Verbinal tries again in \(minutes) min.")
    }

    private func scheduleRetry(after wait: TimeInterval) {
        retry?.cancel()
        let mine = generation
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            self.retryNow()
        }
    }

    /// Tries again now: the bar's Retry, its time come, or the network back.
    func retryNow() {
        retry?.cancel()
        retry = nil
        nextTry = nil
        run(.retry)
    }

    /// The network came back: a sync that failed is tried again at once.
    func networkCameBack() {
        guard nextTry != nil else { return }
        retryNow()
    }

    /// Hears the network come back, once for the app's life.
    func watchNetwork(_ monitor: NetworkPathMonitor) {
        guard !watchingNetwork else { return }
        watchingNetwork = true
        observe(monitor)
    }

    private func observe(_ monitor: NetworkPathMonitor) {
        withObservationTracking {
            _ = monitor.connectivity
        } onChange: { [weak self, weak monitor] in
            Task { @MainActor in
                guard let self, let monitor else { return }
                if monitor.connectivity == .satisfied { self.networkCameBack() }
                self.observe(monitor)
            }
        }
    }

    /// What a sync moved, in words.
    static func moved(imported: Int, sent: Int) -> String {
        switch (imported, sent) {
        case (0, 0): String(localized: "Nothing left to move")
        case (_, 0): String(localized: "\(imported) brought to this Mac")
        case (0, _): String(localized: "\(sent) sent to your storage")
        default: String(localized: "\(imported) brought to this Mac, \(sent) sent")
        }
    }

    /// What waits for the person, in words: "2 to choose in Settings ▸ Storage".
    static func toChoose(_ count: Int) -> String {
        String(localized: "\(count) to choose in Settings ▸ Storage")
    }

    // MARK: - Conflicts (plan 45)

    /// What the person decides: each change two devices made differently,
    /// and each removal one made of what the other changed.
    var conflicts: [SyncConflict] { status?.conflicts ?? [] }

    /// The person's choice on conflict `id` — Settings ▸ Storage's buttons,
    /// or an assistant's resolve_sync_conflict. What it changes on this Mac
    /// goes to storage at once, as a new revision.
    @discardableResult
    func resolve(_ id: String, choosing choice: SyncConflict.Choice) -> Task<Void, Never>? {
        guard let sync, let conflict = conflicts.first(where: { $0.id == id }) else { return nil }
        let mine = generation
        return Task { [weak self] in
            await sync.resolve(id, choosing: choice)
            self?.update(await sync.status(), from: mine)
            if conflict.changes(choosing: choice) { await sync.sync(.asked, only: conflict.kind) }
            self?.update(await sync.status(), from: mine)
        }
    }

    /// The package lists on their way from storage, or paused, for the
    /// discovery sheet's header (plan 40); nil when none are coming.
    var packageListsLine: String? {
        if let paused = status?.paused, paused.kind == "imagePackages" {
            return StorageSettingsTab.pausedLine(paused)
        }
        if let count = current, count.kind == "imagePackages", count.done < count.total {
            return String(localized: "Bringing package lists from your storage — \(count.done) of \(count.total)")
        }
        return nil
    }

    /// Whether package lists are still coming from the person's storage, in
    /// words, for the image tools (plan 40); nil when they are not.
    var packageListsNote: String? {
        if let paused = status?.paused, paused.kind == "imagePackages" {
            let at = paused.done.map { " at \($0) of \(paused.total ?? $0)" } ?? ""
            return "Package lists are still to come from the person's storage: the sync was paused\(at) by \(paused.by). Results may be incomplete; resume_activity resumes it."
        }
        if let count = current, count.kind == "imagePackages", count.done < count.total {
            return "Package lists are still coming from the person's storage: \(count.done) of \(count.total) so far. Results may be incomplete."
        }
        return nil
    }

    /// Sync Now.
    func syncNow() { run(.asked) }

    /// Runs a sync, and reads its status when it ends.
    @discardableResult
    func run(_ reason: StorageSync.Reason, only kind: String? = nil) -> Task<Void, Never>? {
        guard let sync else { return nil }
        let mine = generation
        let task = Task { [weak self] in
            await sync.sync(reason, only: kind)
            self?.update(await sync.status(), from: mine)
        }
        Task { [weak self] in self?.update(await sync.status(), from: mine) }
        return task
    }

    /// A sync's status, unless it is a stopped one's.
    private func update(_ status: StorageSync.Status, from sync: Int) {
        guard sync == generation else { return }
        self.status = status
    }

    private func cameBack() {
        guard let last = status?.lastSync, Date().timeIntervalSince(last) > Self.comeBackAfter else { return }
        run(.cameBack)
    }

    /// Keeps collection `id` in VOSpace, or no longer: declared in the
    /// manifest, or taken out, so every device does the same. A collection
    /// is kept only when the person chooses it; its files stay when they
    /// stop.
    @discardableResult
    func setKeeps(_ id: String, _ keep: Bool) -> Task<Void, Never>? {
        guard let sync else { return nil }
        problem = nil
        let mine = generation
        choices += 1
        let number = choices
        chosen[id] = (keep, number)
        return Task { [weak self] in
            do {
                try await sync.setDeclared([id], keep)
                // Written: the status says it now, before the first sync, which
                // comes after any sync under way.
                self?.update(await sync.status(), from: mine)
                self?.chose(id, number)
                if keep { await sync.sync(.asked, only: id) }
            } catch {
                self?.problem = error.localizedDescription
                self?.chose(id, number)
            }
            self?.update(await sync.status(), from: mine)
        }
    }

    /// A choice written, or failed: the switch shows the manifest again,
    /// unless the person has chosen since.
    private func chose(_ id: String, _ number: Int) {
        if chosen[id]?.number == number { chosen[id] = nil }
    }

    /// A collection changed here: once it settles, its items go, while the
    /// person keeps it in VOSpace. The areas are watched, never told.
    private func watch(_ collection: WorkCollection) {
        withObservationTracking {
            collection.watch()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.sync != nil else { return }
                self.collectionChanged(collection.kind.id)
                self.watch(collection)
            }
        }
    }

    private func collectionChanged(_ id: String) {
        guard keeps(id) else { return }
        changed[id]?.cancel()
        changed[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.changeSettles)
            guard !Task.isCancelled else { return }
            self?.run(.changed, only: id)
        }
    }
}
