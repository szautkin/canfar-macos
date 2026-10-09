// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import Observation
import VerbinalKit

/// The storage sync as the app runs it (plan 34 V): at once after sign-in,
/// in the background and unseen; again when Verbinal comes back to the
/// front and the last sync is over 15 minutes old; a few seconds after
/// Research changes, while Research is kept in VOSpace; and when asked.
/// Nothing after sign-out. Settings ▸ Storage and the tools read its status.
@Observable
@MainActor
final class StorageSyncModel {
    /// What the sync is given of the app, at sign-in.
    struct Dependencies {
        let vospace: VOSpaceBrowserService
        let research: ObservationStore
        let notes: ObservationNoteStore
        let importManifest: @Sendable (Data) async -> Bool
        let resumeRuns: @Sendable () async -> Void
    }

    private(set) var status: StorageSync.Status?
    /// Why the last change of the person's failed.
    private(set) var problem: String?
    private var sync: StorageSync?
    private var research: ObservationStore?
    private var notes: ObservationNoteStore?
    private var researchChange: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    private static let comeBackAfter: TimeInterval = 15 * 60
    private static let researchSettles: Duration = .seconds(5)

    var keepsResearch: Bool { status?.kinds.first { $0.id == "research" }?.declared ?? false }

    /// The kinds this build knows, given what each needs of the app.
    static func catalog(_ deps: Dependencies) -> StorageKindCatalog {
        StorageKindCatalog(kinds: [
            ResearchKind(source: ResearchSyncAdapter(store: deps.research, notes: deps.notes)),
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
        research = deps.research
        notes = deps.notes
        run(.signedIn)
        watchResearch()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
    }

    func signedOut() {
        researchChange?.cancel()
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        let stopping = sync
        Task { await stopping?.stop() }
        sync = nil
        status = nil
        research = nil
        notes = nil
    }

    /// Sync Now.
    func syncNow() { run(.asked) }

    /// Runs a sync, and reads its status when it ends.
    @discardableResult
    func run(_ reason: StorageSync.Reason, only kind: String? = nil) -> Task<Void, Never>? {
        guard let sync else { return nil }
        let task = Task { [weak self] in
            await sync.sync(reason, only: kind)
            let status = await sync.status()
            self?.status = status
        }
        Task { [weak self] in self?.status = await sync.status() }
        return task
    }

    private func cameBack() {
        guard let last = status?.lastSync, Date().timeIntervalSince(last) > Self.comeBackAfter else { return }
        run(.cameBack)
    }

    /// Keep Research in VOSpace, or no longer: declared in the manifest, so
    /// every device does the same. The files stay when it is turned off.
    func setKeepsResearch(_ keep: Bool) {
        guard let sync else { return }
        problem = nil
        Task { [weak self] in
            do {
                try await sync.setDeclared("research", keep)
                await sync.sync(.asked, only: keep ? "research" : nil)
            } catch {
                self?.problem = error.localizedDescription
            }
            self?.status = await sync.status()
        }
    }

    /// Research changed here: once it settles, its records go, while it is
    /// kept in VOSpace. Research is watched, never told.
    private func watchResearch() {
        guard let research, let notes else { return }
        withObservationTracking {
            _ = research.observations
            _ = notes.notes
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.sync != nil else { return }
                self.researchChanged()
                self.watchResearch()
            }
        }
    }

    private func researchChanged() {
        guard keepsResearch else { return }
        researchChange?.cancel()
        researchChange = Task { [weak self] in
            try? await Task.sleep(for: Self.researchSettles)
            guard !Task.isCancelled else { return }
            self?.run(.changed, only: "research")
        }
    }
}
