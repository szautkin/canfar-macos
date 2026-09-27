// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// The Remote Compute screen, for an agent. run_code, start_compute and
/// stop_compute act; these put things on the person's screen — a run to
/// look at, code for them to run — and read back what is there. Setting
/// the image is not here: choosing it is the person's consent to code
/// running on their account.

/// One run in full, as the screen's detail shows it.
struct ComputeRunDetail: Encodable, Sendable, Equatable {
    let executionId: String
    let author: String
    let language: String
    let submittedAt: String
    let status: String
    let exitCode: Int?
    let durationMs: Int?
    let finishedAt: String?
    let timeoutSeconds: Int
    let code: String

    init(_ run: ComputeRun) {
        let iso = ISO8601DateFormatter()
        executionId = run.id
        author = run.author.rawValue
        language = run.language
        submittedAt = iso.string(from: run.submittedAt)
        status = run.state
        exitCode = run.exitCode
        durationMs = run.durationMs
        finishedAt = run.finishedAt.map(iso.string(from:))
        timeoutSeconds = run.timeoutSeconds
        code = run.code
    }
}

/// What the Remote Compute screen shows.
struct ComputeScreenView: Encodable, Sendable, Equatable {
    struct Snippet: Encodable, Sendable, Equatable {
        let language: String
        let timeoutSeconds: Int
        /// Possibly code the person is still writing and has not run.
        let code: String
    }

    /// Whether the screen is on screen now.
    let shown: Bool
    let state: String
    /// `run` (a run's details) or `code` (the Run code box).
    let tab: String
    let selectedRun: ComputeRunDetail?
    let snippet: Snippet
    let message: String?
}

extension RemoteComputeModel {
    /// The screen as an agent reads it.
    func view(shown: Bool, message: String? = nil) -> ComputeScreenView {
        ComputeScreenView(
            shown: shown, state: state.rawValue, tab: tab.rawValue, selectedRun: selectedRun.map(ComputeRunDetail.init),
            snippet: .init(language: language, timeoutSeconds: timeoutSeconds, code: RunCodeContract.normalizeNewlines(code)),
            message: message)
    }
}

// MARK: - get_compute_view

struct GetComputeViewTool: JSONReadTool {
    typealias Args = EmptyArgs

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_compute_view",
        description: "What the Remote Compute screen shows: whether it is on screen, the compute state, which tab is open (run: a run's details; code: the Run code box), the run selected in the list with its full code, and what is in the Run code box — which may be code the person is writing and has not run. Read-only.",
        schema: #"""
        { "type": "object", "properties": {}, "additionalProperties": false }
        """#
    )

    let view: @Sendable () async -> ComputeScreenView

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> ComputeScreenView { await view() }
}

// MARK: - show_compute_run

struct ShowComputeRunTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable { var executionId: String? }

    let definition = AIToolDefinition.withStaticSchema(
        name: "show_compute_run",
        description: "Open the Remote Compute screen with one run selected, so the person sees its code, output and errors — as clicking it in the list does. Omit executionId for the newest run. Returns the screen with the run in full. The person must be signed in. Live-applied.",
        schema: #"""
        {
          "type": "object",
          "properties": { "executionId": { "type": "string", "description": "From list_compute_runs or run_code; omit for the newest." } },
          "additionalProperties": false
        }
        """#
    )

    let show: @Sendable (String?) async throws -> ComputeScreenView

    func handle(_ args: Args, context: AIToolContext) async throws -> ComputeScreenView {
        let id = args.executionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await show(id?.isEmpty == false ? id : nil)
    }
}

// MARK: - set_compute_snippet

/// Fills the Run code box and stops there. Running it is the person's
/// press of Run — or run_code, when the agent means to run it itself. The
/// difference is whose run it is.
struct SetComputeSnippetTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        let code: String
        var language: String?
        var timeoutSeconds: Int?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_compute_snippet",
        description: "Put code in the Remote Compute screen's Run code box, with its language and timeout, and show it — without running it. The person reads it and presses Run, and the run is theirs. To run code yourself, use run_code instead. Replaces whatever was in the box. The person must be signed in. Live-applied.",
        schema: #"""
        {
          "type": "object",
          "required": ["code"],
          "properties": {
            "code": { "type": "string", "minLength": 1 },
            "language": { "type": "string", "enum": ["python", "bash"], "description": "Default python." },
            "timeoutSeconds": { "type": "integer", "minimum": 1, "maximum": 900, "description": "Default 60." }
          },
          "additionalProperties": false
        }
        """#
    )

    let set: @Sendable (Args) async throws -> ComputeScreenView

    func handle(_ args: Args, context: AIToolContext) async throws -> ComputeScreenView {
        guard !args.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolFailureReason.invalidArgument("code is required")
        }
        if let language = args.language, !RunCodeContract.supportedLanguages.contains(language.lowercased()) {
            throw ToolFailureReason.invalidArgument("language must be python or bash")
        }
        return try await set(args)
    }
}
