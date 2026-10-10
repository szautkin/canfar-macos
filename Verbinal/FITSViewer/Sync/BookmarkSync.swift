// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The sky bookmarks every device can use — of a file of Research or of
/// the person's storage, or of no file — as their work in VOSpace (plan 36
/// 4.2). A bookmark of a file of this Mac alone stays.
extension BookmarkStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "bookmarks", defaultFolder: ".verbinal/bookmarks", collection: RecordCollection(
                records: { [weak self] in self?.portable ?? [] },
                key: { $0.id.uuidString },
                changedAt: { $0.savedAt },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] key in UUID(uuidString: key).map { self?.remove(id: $0) } },
                title: { "the sky bookmark \"\($0.label)\"" })),
            watch: { [weak self] in _ = self?.bookmarks })
    }
}
