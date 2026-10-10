// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The Portal's recent launches and the person's launch defaults, as their
/// work in VOSpace (plan 36 3.6). The defaults are the signed-in account's.
extension RecentLaunchStore {
    func syncCollection() -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "recentLaunches", defaultFolder: ".verbinal/launches", collection: RecordCollection(
                records: { [weak self] in self?.launches ?? [] },
                key: { $0.id.uuidString },
                changedAt: { $0.launchedAt },
                keep: { [weak self] in self?.keep($0) },
                remove: { [weak self] key in UUID(uuidString: key).map { self?.remove(id: $0) } },
                title: { "the recent launch \($0.name)" })),
            watch: { [weak self] in _ = self?.launches })
    }
}

extension PortalSettingsService {
    func syncCollection(username: String) -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "portalDefaults", defaultFolder: ".verbinal/portal", collection: RecordCollection(
                records: { [weak self] in self?.settings(for: username).map { [$0] } ?? [] },
                key: { $0.username },
                changedAt: { $0.modifiedAt },
                keep: { [weak self] in self?.keep($0) },
                // The defaults are never removed, only changed.
                remove: { _ in },
                title: { _ in "the Portal's launch defaults" })),
            watch: { [weak self] in _ = self?.settingsByUser })
    }
}
