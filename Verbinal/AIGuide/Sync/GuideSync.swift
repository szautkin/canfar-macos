// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What the person tells assistants, as their work in VOSpace (plan 36
/// 3.4): their guides, their descriptions of Verbinal's tools, and their
/// default session instructions — each an item. What an assistant
/// proposes is applied on its own device first, by the person, and only
/// then travels.
extension AIGuideService {
    func syncCollection(instructions: SessionApprovals) -> WorkCollection {
        WorkCollection(
            kind: CollectionKind(id: "guides", defaultFolder: ".verbinal/guides", collection: RecordCollection(
                records: { [weak self] in (self?.syncEntries() ?? []) + instructions.syncEntries() },
                key: { $0.key },
                changedAt: { $0.modified },
                keep: { [weak self] entry in
                    if entry.kind == .sessionInstructions { instructions.defaultInstructions = entry.text } else { self?.keep(entry) }
                },
                remove: { [weak self] key in
                    guard let (kind, name) = GuideEntry.parse(key: key) else { return }
                    if kind == .sessionInstructions { instructions.defaultInstructions = "" } else { self?.remove(kind, named: name) }
                },
                title: Self.title)),
            watch: { [weak self] in
                _ = self?.guides
                _ = self?.overrides
                _ = instructions.instructionsChangedAt
            })
    }

    @Sendable private static func title(_ entry: GuideEntry) -> String {
        switch entry.kind {
        case .guide: "the guide \(entry.name) for assistants"
        case .toolDescription: "the description of \(entry.name) for assistants"
        case .sessionInstructions: "the default session instructions"
        }
    }
}

extension SessionApprovals {
    /// The person's own default instructions, when they set some.
    func syncEntries() -> [GuideEntry] {
        guard hasOwnInstructions else { return [] }
        return [GuideEntry(kind: .sessionInstructions, name: "", text: defaultInstructions,
                           modified: instructionsChangedAt ?? .distantPast)]
    }
}
