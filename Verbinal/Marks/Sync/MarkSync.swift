// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The marks on files every device knows — of Research, of the person's
/// storage — as their work in VOSpace (plan 36 4.2): each file's (and
/// extension's) marks one item. Marks on a file of this Mac alone stay.
extension MarkStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "marks", defaultFolder: ".verbinal/marks", collection: RecordCollection(
                records: { [weak self] in self?.portableSets ?? [] },
                key: { $0.target },
                changedAt: { $0.changedAt },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] in self?.removeSet($0) },
                title: { "the marks on \(MarkStore.describe(target: $0.target))" })),
            watch: { [weak self] in _ = self?.marksByKey })
    }
}
