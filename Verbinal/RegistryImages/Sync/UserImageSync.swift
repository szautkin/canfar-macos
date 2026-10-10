// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The images the person added to the launch list, as their work in
/// VOSpace (plan 36 3.6).
extension UserImageStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "userImages", defaultFolder: ".verbinal/images", collection: RecordCollection(
                records: { [weak self] in self?.images ?? [] },
                key: { $0.id.lowercased() },
                changedAt: { $0.addedAt ?? .distantPast },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] in _ = self?.remove($0) },
                title: { "the image \($0.id)" })),
            watch: { [weak self] in _ = self?.images })
    }
}
