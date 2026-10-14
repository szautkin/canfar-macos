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

    init(remote: any StorageRemote, catalog: StorageKindCatalog, stateFile: URL,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.remote = remote
        self.catalog = catalog
        self.stateFile = stateFile
        self.now = now
        self.state = StorageSyncState.load(from: stateFile)
    }

    /// Signed out: nothing more runs.
    func stop() {
        stopped = true
        running?.cancel()
    }

    // MARK: - Syncing

    /// Syncs every declared kind, or only `kind`. A sync already under way
    /// is waited for, and a change made meanwhile goes when it ends; an
    /// automatic sync waits longer after each failure.
    func sync(_ reason: Reason, only kind: String? = nil) async {
        guard !stopped else { return }
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
            guard !stopped, queued?.isEmpty != true else { break }
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
        do {
            let manifest = try await currentManifest()
            for id in StorageKindCatalog.order {
                guard !Task.isCancelled, !stopped else { break }
                guard kindIDs?.contains(id) ?? true, let kind = catalog.kind(id),
                      let declared = manifest?.kinds[id] else { continue }
                syncing = id
                await sync(kind, declared: declared)
                syncing = nil
            }
            state.lastSync = now()
            state.lastFailure = nil
            state.failuresInARow = 0
        } catch {
            state.lastSync = now()
            state.lastFailure = error.localizedDescription
            state.failuresInARow += 1
            Self.logger.notice("sync failed: \(error.localizedDescription, privacy: .public)")
        }
        state.save(to: stateFile)
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
            let outcome = try await kind.sync(StorageKindContext(folder: declared.folder, items: items, changed: changed,
                                                                 memory: kindState.memory, remote: remote))
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
            kindState.failure = error.localizedDescription
        }
        state.kinds[kind.id] = kindState
    }

    // MARK: - The manifest

    /// The manifest: as last read when it has not changed, read again when
    /// it has, written when there is none and Verbinal's folders are there.
    /// None for an account without CANFAR storage.
    private func currentManifest() async throws -> StorageManifest? {
        if hasStorage != true { hasStorage = try await remote.hasHome() }
        guard hasStorage == true else { return nil }
        let root = try await remote.list(".verbinal") ?? []
        if let item = root.first(where: { $0.name == "manifest.json" }) {
            if item.stamp == state.manifestStamp, let data = state.manifest, let kept = try? StorageManifest.decode(data) {
                return kept
            }
            let data = try await remote.read(StorageManifest.path)
            let manifest = try StorageManifest.decode(data)
            state.manifestStamp = item.stamp
            state.manifest = data
            return manifest
        }
        return try await firstManifest()
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
                      lastFailure: state.lastFailure, running: running != nil)
    }
}
