// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import VerbinalKit

/// The sync's conflicts, for an assistant (plan 45 F4): what Settings ▸
/// Storage ▸ Conflicts shows, and the person's two choices on each.
struct SyncConflictsOut: Encodable, Sendable {
    struct Conflict: Encodable, Sendable {
        /// What resolve_sync_conflict takes.
        let id: String
        let collection: String
        let collectionTitle: String
        let item: String
        /// `bothChanged`, `removedThere` or `removedHere`.
        let reason: String
        /// As Settings ▸ Storage says it.
        let says: String
        /// For `bothChanged`: each field, this Mac's value and storage's (absent: removed).
        let fields: [Field]
        let otherDevice: String?
        let otherChangedAtISO: String?
        let foundAtISO: String
        /// What each choice does.
        let mine: String
        let theirs: String
    }

    struct Field: Encodable, Sendable {
        let field: String
        let thisMac: JSONValue?
        let storage: JSONValue?
    }

    let conflicts: [Conflict]
    let note: String

    init(_ conflicts: [SyncConflict]) {
        let iso = SharedFormatters.iso8601
        self.conflicts = conflicts.map { conflict in
            Conflict(id: conflict.id, collection: conflict.kind, collectionTitle: StorageSettingsTab.title(conflict.kind),
                     item: conflict.title, reason: conflict.reason.rawValue, says: SyncConflictRow.reasonLine(conflict),
                     fields: conflict.fields.map { Field(field: $0.path.joined(separator: "."), thisMac: $0.mine, storage: $0.theirs) },
                     otherDevice: conflict.otherDevice, otherChangedAtISO: conflict.otherChangedAt.map { iso.string(from: $0) },
                     foundAtISO: iso.string(from: conflict.at),
                     mine: Self.does(conflict, .mine), theirs: Self.does(conflict, .theirs))
        }
        note = "Each waits for the person in Settings ▸ Storage ▸ Conflicts; meanwhile the version in storage is kept, and a change is kept over a removal. resolve_sync_conflict proposes a choice; the person's own choice is theirs to make."
    }

    /// What `choice` does to `conflict`, in a line.
    static func does(_ conflict: SyncConflict, _ choice: SyncConflict.Choice) -> String {
        switch (conflict.reason, choice) {
        case (.bothChanged, .mine): "Keep This Mac's: this Mac's values go to storage and every device, as a new revision"
        case (.bothChanged, .theirs): "Keep the Other's: storage's values stay, as every device has them; nothing is written"
        case (.removedThere, .mine), (.removedHere, .theirs): "OK: it stays, with its change, on every device; nothing is written"
        case (.removedThere, .theirs), (.removedHere, .mine): "Remove It: removed here, and then on every device"
        }
    }
}

/// `list_sync_conflicts` — what the person decides of the storage sync.
struct ListSyncConflictsTool: JSONReadTool {
    struct Args: Decodable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_sync_conflicts",
        description: "List the storage sync's conflicts, as Settings ▸ Storage ▸ Conflicts shows them: a field two devices changed differently (`bothChanged`: storage's value is kept, this Mac's waits), or an item one device removed and the other changed (`removedThere`, `removedHere`: the change is kept). Each with its collection, the item, each field's value on this Mac and in storage, the other device's name, and what each choice does (`mine`, `theirs`). Revisions decide, never a clock. resolve_sync_conflict proposes a choice. Requires sign-in.",
        schema: #"{ "type": "object", "properties": {}, "additionalProperties": false }"#
    )

    let conflicts: @Sendable () async throws -> [SyncConflict]

    func handle(_ args: Args, context: AIToolContext) async throws -> SyncConflictsOut {
        SyncConflictsOut(try await conflicts())
    }
}

/// `resolve_sync_conflict` — a choice on a conflict, as Settings ▸ Storage's
/// buttons make it, proposed to the person.
struct ResolveSyncConflictTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let id: String
        let choice: String
    }

    /// What the person approves: the conflict, the choice, and what it does,
    /// as the conflict said when it was asked — which decides its kind
    /// (`ChangeCatalog.kind(of:)`).
    struct Payload: Codable, Sendable, Equatable {
        let id: String
        let choice: SyncConflict.Choice
        let collection: String
        let removes: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "resolve_sync_conflict",
        description: "Propose a choice on one of the storage sync's conflicts (list_sync_conflicts gives the ids): `mine` keeps this Mac's version, `theirs` the other device's, as Settings ▸ Storage ▸ Conflicts does. For a removal notice, the choice that removes the item is a removal (\"Remove notes and saved things on this Mac\"), and waits unless the person allows it; a conflict on a guide for assistants always waits. What this Mac's choice changes goes to storage and every device at once. Requires sign-in.",
        schema: #"""
        {
          "type": "object",
          "required": ["id", "choice"],
          "properties": {
            "id": { "type": "string", "minLength": 1, "description": "The conflict's id, from list_sync_conflicts." },
            "choice": { "type": "string", "enum": ["mine", "theirs"], "description": "mine: this Mac's version; theirs: the other device's." }
          },
          "additionalProperties": false
        }
        """#
    )

    let conflicts: @Sendable () async throws -> [SyncConflict]

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard let choice = SyncConflict.Choice(rawValue: args.choice) else {
            throw ToolFailureReason.invalidArgument("choice is mine or theirs")
        }
        let waiting = try await conflicts()
        guard let conflict = waiting.first(where: { $0.id == args.id }) else {
            let ids = waiting.map(\.id)
            throw ToolFailureReason.invalidArgument("no conflict \"\(args.id)\" waits\(ids.isEmpty ? "" : "; these do: \(ids.joined(separator: ", "))") — list_sync_conflicts lists them")
        }
        let does = SyncConflictsOut.does(conflict, choice).components(separatedBy: ":").first ?? choice.rawValue
        return try ProposalPlan.encoding(
            kind: "resolve_sync_conflict",
            summary: "\(does): \(SyncConflictRow.heading(conflict))",
            payload: Payload(id: conflict.id, choice: choice, collection: conflict.kind,
                             removes: conflict.removes(choosing: choice)))
    }
}

/// Applies a choice the person approved — if the conflict still waits, and
/// the choice still does what it did when asked.
struct ResolveSyncConflictApplier: ProposalApplier {
    let kind = "resolve_sync_conflict"
    let resolve: @Sendable (ResolveSyncConflictTool.Payload) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(ResolveSyncConflictTool.Payload.self, from: proposal.payload)
        try await resolve(payload)
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
