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

    private(set) var status: StorageSync.Status? {
        didSet { ResultDestination.shared.keeping = keeps("results") }
    }
    /// Why the last change of the person's failed.
    private(set) var problem: String?
    private var sync: StorageSync?
    private var work: [WorkCollection] = []
    private var changed: [String: Task<Void, Never>] = [:]
    private var activation: NSObjectProtocol?
    private static let comeBackAfter: TimeInterval = 15 * 60
    private static let changeSettles: Duration = .seconds(5)

    /// Whether the person keeps collection `id` in VOSpace — their choice,
    /// one collection at a time (plan 36 3.2), declared in the manifest so
    /// every device makes the same.
    func keeps(_ id: String) -> Bool {
        status?.kinds.first { $0.id == id }?.declared ?? false
    }

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
        let sync = StorageSync(remote: VOSpaceStorageRemote(vospace: deps.vospace, username: username),
                               catalog: Self.catalog(deps), stateFile: StorageSyncState.file(for: username))
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

    func signedOut() {
        changed.values.forEach { $0.cancel() }
        changed = [:]
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        ResultDestination.shared.send = nil
        let stopping = sync
        Task { await stopping?.stop() }
        sync = nil
        status = nil
        work = []
    }

    /// Sync Now.
    func syncNow() { run(.asked) }

    /// Runs a sync, and reads its status when it ends.
    @discardableResult
    func run(_ reason: StorageSync.Reason, only kind: String? = nil) -> Task<Void, Never>? {
        guard let sync else { return nil }
        let task = Task { [weak self] in
            await sync.sync(reason, only: kind)
            self?.status = await sync.status()
        }
        Task { [weak self] in self?.status = await sync.status() }
        return task
    }

    private func cameBack() {
        guard let last = status?.lastSync, Date().timeIntervalSince(last) > Self.comeBackAfter else { return }
        run(.cameBack)
    }

    /// Keeps collection `id` in VOSpace, or no longer: declared in the
    /// manifest, or taken out, so every device does the same. A collection
    /// is kept only when the person chooses it; its files stay when they
    /// stop.
    func setKeeps(_ id: String, _ keep: Bool) {
        guard let sync else { return }
        problem = nil
        Task { [weak self] in
            do {
                try await sync.setDeclared([id], keep)
                if keep { await sync.sync(.asked, only: id) }
            } catch {
                self?.problem = error.localizedDescription
            }
            self?.status = await sync.status()
        }
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
