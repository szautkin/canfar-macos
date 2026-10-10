// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The batch jobs CANFAR no longer lists, as the person's work in VOSpace
/// (plan 36 3.6): how each ended, and why, on every device.
extension JobHistoryStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "jobHistory", defaultFolder: ".verbinal/jobs", collection: RecordCollection(
                records: { [weak self] in self?.jobs ?? [] },
                key: { $0.id },
                changedAt: { $0.finishedAt },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] in self?.remove(id: $0) },
                title: { "the batch job \($0.name.isEmpty ? $0.id : $0.name)" })),
            watch: { [weak self] in _ = self?.jobs })
    }
}
