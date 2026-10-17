// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One kind of Verbinal's data kept in VOSpace (plan 34 V): where it lives,
/// and how this device is brought in line with it. One conformer per kind,
/// owned by its feature; the sync knows the kinds, not the features.
protocol StorageKind: Sendable {
    /// The kind's id in the manifest: `imagePackages`.
    var id: String { get }
    /// Its folder from the home, when the manifest does not say another.
    var defaultFolder: String { get }
    /// Where its items are, inside its folder; nil for the folder itself.
    var itemsSubfolder: String? { get }
    /// The item format this build reads and writes.
    var format: Int { get }
    /// Declared in a first manifest when its folder is there. Research waits
    /// for the person.
    var declaredWhenFound: Bool { get }
    /// Brings this device in line with the kind's items: `changed` are the
    /// ones whose date or size differ from what this device last saw.
    func sync(_ context: StorageKindContext) async throws -> StorageKindOutcome
    /// The person's choice on a conflict the kind reported (plan 45).
    func resolve(_ conflict: SyncConflict, choosing choice: SyncConflict.Choice) async
}

extension StorageKind {
    var itemsSubfolder: String? { nil }
    var format: Int { 1 }
    var declaredWhenFound: Bool { true }

    /// The folder its items are in, given where the manifest keeps it.
    func itemsFolder(in folder: String) -> String {
        itemsSubfolder.map { "\(folder)/\($0)" } ?? folder
    }

    func resolve(_ conflict: SyncConflict, choosing choice: SyncConflict.Choice) async {}
}

/// What a kind's sync is given.
struct StorageKindContext: Sendable {
    /// The kind's folder, from the home.
    let folder: String
    /// Its items now (files, not folders).
    let items: [StorageItem]
    /// The items that changed since this device last saw them.
    let changed: [StorageItem]
    /// What this device kept of the kind, between syncs.
    let memory: [String: String]
    let remote: any StorageRemote
    /// This installation, for an item's history (plan 45).
    var device = SyncDevice.unknown
    /// Says how far the kind has got: `done` of `total` items (plan 40).
    var progress: @Sendable (_ done: Int, _ total: Int) async -> Void = { _, _ in }
    /// Keeps an item as taken, at once, so a pause, a quit or a failure goes
    /// on from the next one (plan 40). Only a kind whose items stand alone
    /// says it — the package lists; a collection's memory is kept when it
    /// ends, so a collection stopped halfway runs again.
    var took: @Sendable (StorageItem) async -> Void = { _ in }
}

/// What a kind's sync came to.
struct StorageKindOutcome: Equatable, Sendable {
    /// Items brought to this device, or sent from it.
    var imported = 0
    var sent = 0
    /// What the kind keeps between syncs (Research: what it sent).
    var memory: [String: String]? = nil
    /// A word for the person, when the sync did not do all it could.
    var note: String? = nil
    /// What the person decides (plan 45).
    var conflicts: [SyncConflict] = []
}

/// The one place that lists the kinds this build knows (plan 34 V). Adding
/// a kind is one conformer and one line here.
struct StorageKindCatalog: Sendable {
    let kinds: [any StorageKind]

    func kind(_ id: String) -> (any StorageKind)? { kinds.first { $0.id == id } }

    /// The person's work: the collections they may keep in VOSpace, each by
    /// their own choice (plan 36 3.2), in the order they read them.
    static let work = ["research", "marks", "bookmarks", "workflows", "savedQueries", "recentSearches", "guides",
                       "computeHistory", "jobHistory", "userImages", "recentLaunches", "portalDefaults", "results"]

    /// The ids, in the order the person reads them.
    static let order = work + ["imagePackages", "computeRuns", "stagedScripts", "exports"]
}
