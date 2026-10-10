// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import GRDB

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

/// The guides and tool descriptions, read and kept for the sync (plan 36 3.4).
extension AIGuideService {
    /// The person's guides and tool descriptions, each with when it last changed.
    func syncEntries() -> [GuideEntry] {
        let rows = try? db.reader.read { d in
            (try Row.fetchAll(d, sql: "SELECT name, description, body, updatedAt FROM aiGuideTool WHERE deletedAt IS NULL"),
             try Row.fetchAll(d, sql: "SELECT toolName, userDescription, updatedAt FROM aiToolOverride WHERE deletedAt IS NULL"))
        }
        let guides = rows?.0.compactMap { row -> GuideEntry? in
            guard let name: String = row["name"], let text: String = row["description"] else { return nil }
            return GuideEntry(kind: .guide, name: name, text: text, body: row["body"], modified: Self.date(row["updatedAt"]))
        } ?? []
        let descriptions = rows?.1.compactMap { row -> GuideEntry? in
            guard let name: String = row["toolName"], let text: String = row["userDescription"] else { return nil }
            return GuideEntry(kind: .toolDescription, name: name, text: text, modified: Self.date(row["updatedAt"]))
        } ?? []
        return guides + descriptions
    }

    /// Keeps a guide or a tool's description as another device has it.
    func keep(_ entry: GuideEntry) {
        switch entry.kind {
        case .guide:
            if let guide = guides.first(where: { $0.name == entry.name }) {
                try? updateGuide(id: guide.id, name: entry.name, description: entry.text, body: entry.body)
            } else {
                try? addGuide(name: entry.name, description: entry.text, body: entry.body)
            }
        case .toolDescription:
            try? setOverride(toolName: entry.name, description: entry.text)
        case .sessionInstructions:
            break
        }
    }

    /// Removes a guide, or puts a tool's description back: another device did.
    func remove(_ kind: GuideEntry.Kind, named name: String) {
        switch kind {
        case .guide: if let guide = guides.first(where: { $0.name == name }) { deleteGuide(id: guide.id) }
        case .toolDescription: clearOverride(toolName: name)
        case .sessionInstructions: break
        }
    }

    private static func date(_ text: String?) -> Date {
        text.flatMap { isoFormatter.date(from: $0) } ?? .distantPast
    }
}
