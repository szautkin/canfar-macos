// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import VerbinalKit

// MARK: - start_background_apply

/// Apply a pending proposal without holding the call open — for work that
/// takes longer than a client waits for a tool (a whole-observation
/// download, a large VOSpace transfer).
struct StartBackgroundApplyTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        let proposalId: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "start_background_apply",
        description: "Apply a pending proposal in the background instead of waiting for it — for work longer than a tool call should be held open (a whole-observation download, a large VOSpace transfer). Answers at once with a job id (the proposal's own id); follow it with get_job_status. Only for a change of a kind the person allows without asking (Settings ▸ AI Agent; each tool's description ends with its kind's setting): a kind they ask to approve, and anything that changes what every assistant is told, waits for them in Verbinal — this never starts it, and says so. (An auto-applied write that runs long already continues as a job by itself.)",
        schema: #"""
        {
          "type": "object",
          "required": ["proposalId"],
          "properties": { "proposalId": { "type": "string", "description": "A pending proposal's id (list_pending_proposals)." } },
          "additionalProperties": false
        }
        """#
    )

    let start: @Sendable (_ proposalId: String) async -> AgentsService.BackgroundStart

    func handle(_ args: Args, context: AIToolContext) async throws -> AgentsService.BackgroundStart {
        await start(args.proposalId)
    }
}

// MARK: - get_job_status

struct GetJobStatusTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let jobId: String
    }

    struct Output: Encodable, Sendable {
        let jobId: String
        /// running / succeeded / failed for a job; otherwise the proposal's
        /// state (pending, applying, applied, rejected, withdrawn, failed, unknown).
        let status: String
        let kind: String?
        let summary: String?
        let elapsedSeconds: Double?
        let message: String?
        /// What the apply reported on success (a new id, bulk results…).
        let result: JSONValue?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_job_status",
        description: "How a background job is getting on — one started by start_background_apply, or an auto-applied write that was still applying when its call answered (`applying: true`, with a jobId). `status` is running, succeeded or failed, with `elapsedSeconds`, the failure `message`, or the apply's `result`. For an id that never ran as a job, the proposal's own state.",
        schema: #"""
        {
          "type": "object",
          "required": ["jobId"],
          "properties": { "jobId": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let status: @Sendable (_ jobId: String) async -> (job: ApplyJobRegistry.Job?, state: ProposalState)?

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard let found = await status(args.jobId) else {
            throw ToolFailureReason.invalidArgument("'\(args.jobId)' is not a job id — it is the proposal's UUID")
        }
        guard let job = found.job else {
            return Output(jobId: args.jobId, status: found.state.rawValue, kind: nil, summary: nil,
                          elapsedSeconds: nil, message: nil, result: nil)
        }
        let end = job.finished ?? Date()
        return Output(
            jobId: args.jobId, status: job.status.rawValue, kind: job.kind, summary: job.summary,
            elapsedSeconds: (end.timeIntervalSince(job.started) * 10).rounded() / 10,
            message: job.message,
            result: job.result.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) })
    }
}
