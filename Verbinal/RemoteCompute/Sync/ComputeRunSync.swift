// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The runs sent to Remote Compute, as the person's work in VOSpace (plan
/// 36 3.6): who sent what, on which image, and how it ended. The results
/// are in storage already, in `.verbinal/exec/out`.
extension ComputeRunStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "computeHistory", defaultFolder: ".verbinal/compute-history", collection: RecordCollection(
                records: { [weak self] in self?.runs ?? [] },
                key: { $0.id.lowercased() },
                changedAt: { $0.finishedAt ?? $0.submittedAt },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] in self?.remove(id: $0) },
                title: { "the Remote Compute run \($0.id)" })),
            watch: { [weak self] in _ = self?.runs })
    }
}
