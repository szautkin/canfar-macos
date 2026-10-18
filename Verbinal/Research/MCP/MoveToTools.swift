// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Move To for assistants (plan 46 M5): the sheet as the person sees it,
/// opened with an assistant's choice for the person to press, and the
/// button's moves as a proposal of the kind of what they do.
struct MoveToView: Encodable, Sendable {
    struct File: Encodable, Sendable {
        let name: String
        let size: Int64?
        /// Where it is now, and will be: `mac`, `storage`, `both`.
        let now: String
        let after: String
        /// `copy to storage`, `move to mac`, `remove from mac` …; absent when held.
        let does: String?
        /// Why it does not go: already there, gone from this Mac, or storage's refusal.
        let held: String?
        let checked: Bool
        /// While the button's moves run: `moving`, then `moved`.
        let moving: String?
    }

    let open: Bool
    let record: String?
    let title: String?
    let to: String?
    let keepCopy: Bool?
    /// Every file was in both places: the choice is which copy to keep.
    let keepOnly: Bool?
    let files: [File]
    let summary: [String]
    let warnings: [String]
    let button: String?
    let canRun: Bool?
    let freeBytes: Int64?
    let note: String

    static let closed = MoveToView(open: false, record: nil, title: nil, to: nil, keepCopy: nil, keepOnly: nil, files: [],
                                   summary: [], warnings: [], button: nil, canRun: nil, freeBytes: nil,
                                   note: "Move To is not open: show_move_to opens it on a record.")

    @MainActor
    init(_ sheet: MoveToModel) {
        let plan = sheet.plan
        self.init(open: true, record: sheet.recordID.uuidString, title: sheet.title, to: plan.to.rawValue,
                  keepCopy: plan.keepCopy, keepOnly: plan.isKeepOnly,
                  files: plan.rows.map { row in
                      File(name: row.name, size: row.size, now: row.now.word, after: row.after.word,
                           does: row.step.map(Self.words), held: row.held.map(Self.words), checked: row.checked,
                           moving: sheet.moving[row.name].map { $0 == .moving ? "moving" : "moved" })
                  },
                  summary: plan.summary, warnings: plan.warnings, button: plan.buttonTitle, canRun: plan.canRun,
                  freeBytes: plan.free,
                  note: "What the person sees in Move To. Its button is the person's to press; move_research_files proposes the same moves.")
    }

    private init(open: Bool, record: String?, title: String?, to: String?, keepCopy: Bool?, keepOnly: Bool?,
                 files: [File], summary: [String], warnings: [String], button: String?, canRun: Bool?,
                 freeBytes: Int64?, note: String) {
        self.open = open
        self.record = record
        self.title = title
        self.to = to
        self.keepCopy = keepCopy
        self.keepOnly = keepOnly
        self.files = files
        self.summary = summary
        self.warnings = warnings
        self.button = button
        self.canRun = canRun
        self.freeBytes = freeBytes
        self.note = note
    }

    static func words(_ step: MoveToPlan.Step) -> String {
        switch step {
        case .copy(let to): "copy to \(to.rawValue)"
        case .move(let to): "move to \(to.rawValue)"
        case .remove(let from): "remove from \(from.rawValue)"
        }
    }

    static func words(_ held: MoveToPlan.Held) -> String {
        switch held {
        case .alreadyThere: "already there"
        case .notOnMac: "not on this Mac any more"
        case .refused(let why): why
        }
    }
}

/// What both tools that set Move To take: the record, and the choice.
struct MoveToArgs: Codable, Sendable, Equatable {
    let id: String
    var to: String?
    var keepCopy: Bool?
    /// The files to act on, by name; omitted: those that can go.
    var files: [String]?

    static let schema = #"""
    {
      "type": "object",
      "required": ["id"],
      "properties": {
        "id": { "type": "string", "minLength": 1, "description": "The record: its downloaded_observation_id (or its first 8+ hex digits), publisher id, or observation id. A cutout is its own record, not its original." },
        "to": { "type": "string", "enum": ["storage", "mac"], "description": "Where the files go; omitted: where they are not. When every file is in both places, the copy kept." },
        "keepCopy": { "type": "boolean", "description": "true (the default): copy, keeping the files where they are too. false: move, removing that copy once the new one is there." },
        "files": { "type": "array", "items": { "type": "string" }, "description": "The record's files to act on, by name; omitted: every one that can go." }
      },
      "additionalProperties": false
    }
    """#
}

// MARK: - get_move_to_view

struct GetMoveToViewTool: JSONReadTool {
    struct Args: Decodable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_move_to_view",
        description: "Read the Move To sheet as the person sees it: the record, where its files go (`to`), copy or move (`keepCopy`), each file now and after (`mac`, `storage`, `both`), what it does or why it is held, which are checked, the summary and its warnings, the button's words and whether it can be pressed, and storage's free space. `open: false` when it is not showing. Read-only.",
        schema: #"{ "type": "object", "properties": {}, "additionalProperties": false }"#
    )

    let view: @Sendable () async -> MoveToView

    func handle(_ args: Args, context: AIToolContext) async throws -> MoveToView { await view() }
}

// MARK: - show_move_to

struct ShowMoveToTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }
    typealias Args = MoveToArgs

    let definition = AIToolDefinition.withStaticSchema(
        name: "show_move_to",
        description: "Open Move To on a Research record — selecting it, as the person's click would — with your choice set: where the files go, copy or move, which files. The person sees it and presses the button themselves; nothing moves until they do. Answers the sheet as get_move_to_view reads it. Needs CANFAR sign-in. Live-applied.",
        schema: MoveToArgs.schema
    )

    let show: @Sendable (MoveToArgs) async throws -> MoveToView

    func handle(_ args: Args, context: AIToolContext) async throws -> MoveToView { try await show(args) }
}

// MARK: - move_research_files

struct MoveResearchFilesTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    typealias Args = MoveToArgs

    /// What the person approves: the record, the choice, the files it acts
    /// on, and which copy it removes, if any — which decides its kind.
    struct Payload: Codable, Sendable, Equatable {
        let id: String
        let to: String
        let keepCopy: Bool
        let files: [String]
        /// `mac` or `storage`: the copy it removes; nil when it only copies.
        let removes: String?
        let summary: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "move_research_files",
        description: "Copy or move a Research record's files between this Mac and the person's storage, as Move To's button does: `to` storage or mac (omitted: where they are not), `keepCopy` true (the default: copy) or false (move: the copy left is removed once the new one is there), `files` by name (omitted: every one that can go). When every file is in both places, `to` is the copy kept, and the other is removed. Its kind is what it does: a copy to storage is \"Add to your CANFAR storage\", a copy to this Mac \"Files saved on this Mac\"; a move or a kept copy removes, and is \"Remove files on this Mac\" or \"Remove or replace in your CANFAR storage\". Refused when asked for what Move To would not do, saying why. Each file moves as a task on the activity bar. Needs CANFAR sign-in.",
        schema: MoveToArgs.schema
    )

    /// Judges the choice when it is asked: what it does, or why not.
    let check: @Sendable (MoveToArgs) async throws -> Payload

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let payload = try await check(args)
        return try ProposalPlan.encoding(kind: "move_research_files", summary: payload.summary, payload: payload)
    }
}

/// Makes the moves the person approved — if they still do what they did.
struct MoveResearchFilesApplier: ResultReportingApplier {
    let kind = "move_research_files"
    let run: @Sendable (MoveResearchFilesTool.Payload) async throws -> AutoAppliedAck.Extra
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(MoveResearchFilesTool.Payload.self, from: proposal.payload)
        let extra = try await run(payload)
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        return (try? JSONEncoder().encode(extra)) ?? Data()
    }
}
