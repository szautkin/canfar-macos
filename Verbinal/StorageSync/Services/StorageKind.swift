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
}

extension StorageKind {
    var itemsSubfolder: String? { nil }
    var format: Int { 1 }
    var declaredWhenFound: Bool { true }

    /// The folder its items are in, given where the manifest keeps it.
    func itemsFolder(in folder: String) -> String {
        itemsSubfolder.map { "\(folder)/\($0)" } ?? folder
    }
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
}

/// The one place that lists the kinds this build knows (plan 34 V). Adding
/// a kind is one conformer and one line here.
struct StorageKindCatalog: Sendable {
    let kinds: [any StorageKind]

    func kind(_ id: String) -> (any StorageKind)? { kinds.first { $0.id == id } }

    /// The person's work: the collections they may keep in VOSpace, each by
    /// their own choice (plan 36 3.2), in the order they read them.
    static let work = ["research", "workflows", "savedQueries", "recentSearches", "guides",
                       "computeHistory", "jobHistory", "userImages", "recentLaunches", "portalDefaults"]

    /// The ids, in the order the person reads them.
    static let order = work + ["imagePackages", "computeRuns", "stagedScripts", "exports"]
}
