// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Saved queries and recent searches as the person's work in VOSpace
/// (plan 36 3.5): each one an item, by its id.
extension SavedQueryStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "savedQueries", defaultFolder: ".verbinal/queries", collection: RecordCollection(
                records: { [weak self] in self?.queries ?? [] },
                key: { $0.id.uuidString },
                changedAt: { $0.changedAt ?? $0.savedAt },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] key in UUID(uuidString: key).map { self?.remove(id: $0) } },
                title: { "the saved query \"\($0.name)\"" })),
            watch: { [weak self] in _ = self?.queries })
    }
}

extension RecentSearchStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "recentSearches", defaultFolder: ".verbinal/recent-searches", collection: RecordCollection(
                records: { [weak self] in self?.searches ?? [] },
                key: { $0.id.uuidString },
                changedAt: { $0.changedAt ?? $0.savedAt },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] key in UUID(uuidString: key).map { self?.remove(id: $0) } },
                title: { "the recent search \"\($0.name)\"" })),
            watch: { [weak self] in _ = self?.searches })
    }
}
