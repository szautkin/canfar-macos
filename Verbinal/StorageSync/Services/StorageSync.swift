// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log
import VerbinalKit

/// Brings this device in line with the Verbinal data the person keeps in
/// VOSpace (plan 34 V). It knows the manifest and the catalogue, not the
/// features: it reads `.verbinal/` (one listing), the manifest only when
/// its size or date changed, then one listing of each declared kind's
/// folder, and hands each kind what changed. One sync at a time; it never
/// deletes.
actor StorageSync {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "StorageSync")

    /// Where a collection stands (plan 38): not kept in storage, waiting
    /// for its first sync, syncing now, synced (when), or why not.
    enum CollectionState: Equatable, Sendable {
        case off, waiting, syncing
        case synced(Date)
        case failed(String)

        /// Its state as an assistant reads it.
        var name: String {
            switch self {
            case .off: "off"
            case .waiting: "waiting"
            case .syncing: "syncing"
            case .synced: "synced"
            case .failed: "failed"
            }
        }

        /// The one reading of what the sync knows of a kind.
        static func of(declared: Bool, syncingNow: Bool, failure: String?, lastSync: Date?) -> Self {
            guard declared else { return .off }
            if syncingNow { return .syncing }
            if let failure { return .failed(failure) }
            return lastSync.map(Self.synced) ?? .waiting
        }
    }

    /// What the person and an assistant are told of a kind.
    struct KindStatus: Equatable, Sendable {
        let id: String
        let declared: Bool
        let folder: String
        let items: Int
        let bytes: Int64
        let lastSync: Date?
        let imported: Int
        let sent: Int
        let note: String?
        let failure: String?
        var state: CollectionState = .off
    }

    struct Status: Equatable, Sendable {
        /// Whether the account has CANFAR storage; nil until a sync looked.
        var hasStorage: Bool?
        var hasManifest: Bool
        var kinds: [KindStatus]
        var lastSync: Date?
        var lastFailure: String?
        var running: Bool
        /// Who paused it, why, when, and where it had got to (plan 40).
        var paused: StorageSyncState.Paused? = nil
        /// The kind syncing now, and how far it has got.
        var progress: Progress? = nil
        /// Its task on the activity bar, when it is there (the app's to say).
        var activityTask: Int? = nil
    }

    /// How far a kind has got (plan 40).
    struct Progress: Equatable, Sendable {
        let kind: String
        let done: Int
        let total: Int
    }

    /// What a sync tells its watcher as it goes (plan 40).
    enum Event: Equatable, Sendable {
        /// A kind's count.
        case progress(Progress)
        /// The run is over: what moved, and why it failed, if it did; or it
        /// was paused, and goes on when resumed.
        case ended(imported: Int, sent: Int, failure: String?, paused: Bool)
    }

    /// Why a sync runs.
    enum Reason: String, Sendable {
        case signedIn, cameBack, changed, asked
        /// An automatic sync waits after failures; one asked for does not.
        var isAutomatic: Bool { self != .asked }
    }

    private let remote: any StorageRemote
    private let catalog: StorageKindCatalog
    private let stateFile: URL
    private let now: @Sendable () -> Date
    private var state: StorageSyncState
    private var running: Task<Void, Never>?
    /// The collection a sync is on now.
    private var syncing: String?
    /// What changed while a sync ran: it goes when that sync ends (nil: every kind).
    private var queued: Set<String>? = []
    /// Whether the account has CANFAR storage, once a sync looked: without
    /// it nothing is read or written, and only a sync asked for looks again.
    private var hasStorage: Bool?
    private var stopped = false
    /// The kinds whose folder outside `.verbinal` was looked for since sign-in.
    private var lookedFor: Set<String> = []
    /// The kind syncing now, and how far it has got.
    private var progress: Progress?
    /// Who hears how a sync goes: each kind's count and each run's end.
    private let watcher: (@Sendable (Event) async -> Void)?
    /// Items taken since the state was last written: it is written at most
    /// every `saveEvery` items or `saveAfter` seconds while a kind runs.
    private var takenSinceSave = 0
    private var savedAt = Date.distantPast
    static let saveEvery = 25
    static let saveAfter: TimeInterval = 5

    init(remote: any StorageRemote, catalog: StorageKindCatalog, stateFile: URL,
         now: @escaping @Sendable () -> Date = Date.init,
         watcher: (@Sendable (Event) async -> Void)? = nil) {
        self.remote = remote
        self.catalog = catalog
        self.stateFile = stateFile
        self.now = now
        self.watcher = watcher
        self.state = StorageSyncState.load(from: stateFile)
    }

    /// Signed out: nothing more runs.
    func stop() {
        stopped = true
        running?.cancel()
    }

    // MARK: - Pausing (plan 40)

    /// Pauses the sync where it is, for `by`: the item under way finishes,
    /// what was taken is kept, and nothing runs — after sign-in, on coming
    /// back, after a change, or asked — until it is resumed. Kept with the
    /// state, so a relaunch does not resume it.
    func pause(by: Initiator, why: String?) {
        guard state.paused == nil else { return }
        state.paused = .init(by: by.rawValue, why: why, at: now(), kind: progress?.kind,
                             done: progress?.done, total: progress?.total)
        state.save(to: stateFile)
        running?.cancel()
    }

    /// Resumes it: the next sync goes on from where it stopped.
    func resume() {
        guard state.paused != nil else { return }
        state.paused = nil
        state.save(to: stateFile)
    }

    var isPaused: Bool { state.paused != nil }

    // MARK: - Syncing

    /// Syncs every declared kind, or only `kind`. A sync already under way
    /// is waited for, and a change made meanwhile goes when it ends; an
    /// automatic sync waits longer after each failure.
    func sync(_ reason: Reason, only kind: String? = nil) async {
        guard !stopped, state.paused == nil else { return }
        if let running {
            guard reason == .changed else { return await running.value }
            if let kind { queued?.insert(kind) } else { queued = nil }
            return
        }
        if reason.isAutomatic, hasStorage == false { return }
        if reason.isAutomatic, let wait = backOff(), now().timeIntervalSince(state.lastSync ?? .distantPast) < wait {
            return
        }
        var only: Set<String>? = kind.map { [$0] }
        var why = reason
        while true {
            let task = Task(priority: .background) { [only, why] in await self.run(why, only: only) }
            running = task
            await task.value
            running = nil
            guard !stopped, state.paused == nil, queued?.isEmpty != true else { break }
            only = queued
            queued = []
            why = .changed
        }
    }

    /// How long an automatic sync waits after failures in a row: 1, 2, 4 …
    /// minutes, at most an hour; nil after a success.
    private func backOff() -> TimeInterval? {
        guard state.failuresInARow > 0 else { return nil }
        return min(3600, 60 * pow(2, Double(state.failuresInARow - 1)))
    }

    private func run(_ reason: Reason, only kindIDs: Set<String>?) async {
        Self.logger.info("sync (\(reason.rawValue, privacy: .public)) begins")
        var imported = 0, sent = 0
        var failure: String?
        do {
            let manifest = try await currentManifest()
            for id in StorageKindCatalog.order {
                guard !Task.isCancelled, !stopped else { break }
                guard kindIDs?.contains(id) ?? true, let kind = catalog.kind(id),
                      let declared = manifest?.kinds[id] else { continue }
                syncing = id
                await sync(kind, declared: declared)
                syncing = nil
                progress = nil
                let kept = state.kinds[id]
                imported += kept?.imported ?? 0
                sent += kept?.sent ?? 0
                if failure == nil, let kindFailure = kept?.failure { failure = kindFailure }
            }
            state.lastSync = now()
            state.lastFailure = nil
            state.failuresInARow = 0
        } catch {
            state.lastSync = now()
            state.lastFailure = error.localizedDescription
            state.failuresInARow += 1
            failure = error.localizedDescription
            Self.logger.notice("sync failed: \(error.localizedDescription, privacy: .public)")
        }
        syncing = nil
        progress = nil
        state.save(to: stateFile)
        await watcher?(.ended(imported: imported, sent: sent, failure: failure, paused: state.paused != nil))
    }

    /// A kind's count, for its watcher and its status.
    private func counted(_ kind: String, _ done: Int, _ total: Int) async {
        let count = Progress(kind: kind, done: done, total: total)
        progress = count
        // The item under way when it was paused finishes: where it stopped.
        if state.paused != nil {
            state.paused?.kind = kind
            state.paused?.done = done
            state.paused?.total = total
        }
        await watcher?(.progress(count))
    }

    /// An item a kind took: kept at once, the state written now and then.
    private func took(_ item: StorageItem, of kind: String) {
        state.kinds[kind, default: .init()].items[item.name] = item.stamp
        takenSinceSave += 1
        if takenSinceSave >= Self.saveEvery || now().timeIntervalSince(savedAt) >= Self.saveAfter {
            state.save(to: stateFile)
            takenSinceSave = 0
            savedAt = now()
        }
    }

    private func sync(_ kind: any StorageKind, declared: StorageManifest.Kind) async {
        var kindState = state.kinds[kind.id] ?? .init()
        guard declared.format <= kind.format else {
            kindState.note = "written by a newer Verbinal (format \(declared.format)): left as it is"
            state.kinds[kind.id] = kindState
            return
        }
        do {
            let folder = kind.itemsFolder(in: declared.folder)
            let items = (try await remote.list(folder) ?? []).filter { !$0.isFolder }
            let changed = items.filter { kindState.items[$0.name] != $0.stamp }
            let id = kind.id
            let outcome = try await kind.sync(StorageKindContext(
                folder: declared.folder, items: items, changed: changed, memory: kindState.memory, remote: remote,
                progress: { [weak self] done, total in await self?.counted(id, done, total) },
                took: { [weak self] item in await self?.took(item, of: id) }))
            // Paused or stopped halfway: what it took is kept, item by item;
            // the rest is still to come, not seen.
            if Task.isCancelled { return }
            // What it sent changed the folder: look again, so the next sync
            // does not take its own writes for someone else's.
            let seen = outcome.sent > 0 ? (try await remote.list(folder) ?? items).filter { !$0.isFolder } : items
            kindState.items = Dictionary(seen.map { ($0.name, $0.stamp) }, uniquingKeysWith: { first, _ in first })
            kindState.bytes = seen.compactMap(\.size).reduce(0, +)
            kindState.lastSync = now()
            kindState.imported = outcome.imported
            kindState.sent = outcome.sent
            kindState.note = outcome.note
            kindState.failure = nil
            if let memory = outcome.memory { kindState.memory = memory }
        } catch {
            if Task.isCancelled { return }
            kindState = state.kinds[kind.id] ?? kindState
            kindState.failure = error.localizedDescription
        }
        state.kinds[kind.id] = kindState
    }

    // MARK: - The manifest

    /// The manifest: as last read when it has not changed, read again when
    /// it has, written when there is none and Verbinal's folders are there,
    /// and added to when one of them came after it. None for an account
    /// without CANFAR storage.
    private func currentManifest() async throws -> StorageManifest? {
        if hasStorage != true { hasStorage = try await remote.hasHome() }
        guard hasStorage == true else { return nil }
        let root = try await remote.list(".verbinal") ?? []
        guard let item = root.first(where: { $0.name == "manifest.json" }) else { return try await firstManifest() }
        let manifest: StorageManifest
        if item.stamp == state.manifestStamp, let data = state.manifest, let kept = try? StorageManifest.decode(data) {
            manifest = kept
        } else {
            let data = try await remote.read(StorageManifest.path)
            manifest = try StorageManifest.decode(data)
            state.manifestStamp = item.stamp
            state.manifest = data
        }
        return try await declaringFound(in: manifest, root: root)
    }

    /// The manifest, with the kinds of Verbinal's own data whose folder is
    /// there though it does not declare them — it was written before the
    /// folder was, when the person kept their first collection there
    /// (plan 40 A). One write declares them all. A folder in `.verbinal` is
    /// seen in its listing; one elsewhere is looked for once a sign-in. The
    /// kinds the person chooses are never declared this way.
    private func declaringFound(in manifest: StorageManifest, root: [StorageItem]) async throws -> StorageManifest {
        var found: [any StorageKind] = []
        for kind in catalog.kinds where kind.declaredWhenFound && !manifest.declares(kind.id) {
            let inVerbinal = kind.defaultFolder.hasPrefix(".verbinal/") ? String(kind.defaultFolder.dropFirst(".verbinal/".count)) : nil
            if let inVerbinal, !inVerbinal.contains("/") {
                if root.contains(where: { $0.isFolder && $0.name == inVerbinal }) { found.append(kind) }
            } else if lookedFor.insert(kind.id).inserted, try await remote.list(kind.defaultFolder) != nil {
                found.append(kind)
            }
        }
        guard !found.isEmpty else { return manifest }
        var latest = try await latestManifest() ?? manifest
        let adding = found.filter { !latest.declares($0.id) }
        guard !adding.isEmpty else { return latest }
        for kind in adding {
            latest.kinds[kind.id] = .init(folder: kind.defaultFolder, format: kind.format, since: now())
        }
        try await write(latest, why: "Verbinal declares in VOSpace the kinds of its data found there, for every device: "
                        + adding.map(\.id).joined(separator: ", "))
        return latest
    }

    /// No manifest: one declaring the kinds whose folders are there — the
    /// person's probes, runs, scripts and exports from before. Nothing when
    /// there are none: Verbinal makes no folder of its own for nothing.
    private func firstManifest() async throws -> StorageManifest? {
        var manifest = StorageManifest()
        for kind in catalog.kinds where kind.declaredWhenFound {
            if try await remote.list(kind.defaultFolder) != nil {
                manifest.kinds[kind.id] = .init(folder: kind.defaultFolder, format: kind.format, since: now())
            }
        }
        guard !manifest.kinds.isEmpty else { return nil }
        try await write(manifest, why: "Verbinal declares in VOSpace the kinds of its data kept there, for every device")
        return manifest
    }

    private func write(_ manifest: StorageManifest, why: String) async throws {
        let data = manifest.encoded()
        try await Initiator.$current.withValue(.app) {
            try await Cause.$current.withValue(Cause(why: why)) {
                try await remote.write(data, to: StorageManifest.path)
            }
        }
        let item = try await remote.list(".verbinal")?.first { $0.name == "manifest.json" }
        state.manifestStamp = item?.stamp
        state.manifest = data
    }

    /// Declares `kinds` in the manifest — the person keeps their work in
    /// VOSpace — or, with `declared` false, takes them out; their files
    /// stay. One write, whatever the number.
    func setDeclared(_ kindIDs: [String], _ declared: Bool) async throws {
        if hasStorage != true { hasStorage = try await remote.hasHome() }
        guard hasStorage == true else { throw NoStorage() }
        var manifest = try await latestManifest() ?? StorageManifest()
        let changing = kindIDs.compactMap { catalog.kind($0) }.filter { manifest.declares($0.id) != declared }
        guard !changing.isEmpty else { return }
        for kind in changing {
            if declared {
                manifest.kinds[kind.id] = .init(folder: kind.defaultFolder, format: kind.format, since: now())
            } else {
                manifest.kinds.removeValue(forKey: kind.id)
            }
        }
        let what = changing.map(\.id).joined(separator: ", ")
        try await write(manifest, why: declared
            ? "the person keeps their work in VOSpace, for every device: \(what)"
            : "the person no longer keeps their work in VOSpace (\(what)); its files stay")
        state.save(to: stateFile)
    }

    /// The manifest as it is now in VOSpace, read whatever was kept: a write
    /// starts from it, so another device's kinds are not lost.
    private func latestManifest() async throws -> StorageManifest? {
        guard try await remote.list(".verbinal")?.contains(where: { $0.name == "manifest.json" }) == true else { return nil }
        return try StorageManifest.decode(try await remote.read(StorageManifest.path))
    }

    /// The account has no CANFAR storage: nothing can be kept there.
    struct NoStorage: LocalizedError {
        var errorDescription: String? {
            String(localized: "Your account has no CANFAR storage, so your work stays on this Mac.")
        }
    }

    // MARK: - Status

    func status() -> Status {
        let manifest = state.manifest.flatMap { try? StorageManifest.decode($0) }
        let kinds = StorageKindCatalog.order.compactMap { id -> KindStatus? in
            guard let kind = catalog.kind(id) else { return nil }
            let kept = state.kinds[id]
            return KindStatus(id: id, declared: manifest?.declares(id) ?? false,
                              folder: manifest?.kinds[id]?.folder ?? kind.defaultFolder,
                              items: kept?.items.count ?? 0, bytes: kept?.bytes ?? 0, lastSync: kept?.lastSync,
                              imported: kept?.imported ?? 0, sent: kept?.sent ?? 0, note: kept?.note, failure: kept?.failure,
                              state: .of(declared: manifest?.declares(id) ?? false, syncingNow: syncing == id,
                                         failure: kept?.failure, lastSync: kept?.lastSync))
        }
        return Status(hasStorage: hasStorage, hasManifest: manifest != nil, kinds: kinds, lastSync: state.lastSync,
                      lastFailure: state.lastFailure, running: running != nil, paused: state.paused, progress: progress)
    }
}
