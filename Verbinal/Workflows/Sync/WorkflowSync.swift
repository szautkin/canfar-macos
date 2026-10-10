// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The workflows as the person's work in VOSpace: each working copy an
/// item, by its file name. The templates come with the app.
extension WorkflowStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "workflows", defaultFolder: ".verbinal/workflows", collection: RecordCollection(
                records: { [weak self] in self?.files() ?? [] },
                key: { $0.slug },
                changedAt: { $0.modified },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] in self?.removeFile(slug: $0) },
                title: { "the workflow \"\(WorkflowFormat.parse($0.text).title)\"" })),
            watch: { [weak self] in _ = self?.changeID })
    }
}
