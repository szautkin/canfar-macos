// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `list_job_history` — the batch jobs CANFAR no longer lists, and why
/// they ended, as the Batch Jobs sheet's History shows them.
struct ListJobHistoryTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        var limit: Int?
        /// Only failures (default false).
        var failedOnly: Bool?
    }

    struct Output: Encodable, Sendable {
        let total: Int
        let jobs: [Entry]
    }

    struct Entry: Encodable, Sendable, Equatable {
        let id: String
        let name: String
        let image: String
        /// user (the person's batch job), agent (one an assistant launched) or
        /// imageProbe (image discovery's own).
        let origin: String
        /// succeeded or failed.
        let outcome: String
        let status: String
        let startedAt: String?
        let finishedAt: String
        let failureReason: String?
        let targetImage: String?

        init(_ job: JobRecord) {
            id = job.id
            name = job.name
            image = job.image
            origin = job.origin.rawValue
            outcome = job.outcome.rawValue
            status = job.status
            startedAt = job.startedAt.isEmpty ? nil : job.startedAt
            finishedAt = ISO8601DateFormatter().string(from: job.finishedAt)
            failureReason = job.failureReason
            targetImage = job.targetImage
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_job_history",
        description: "Finished batch jobs the app remembers after CANFAR has removed them — the Batch Jobs sheet's History: the person's own and those an assistant launched (`origin: agent`) — list_headless_jobs shows only what the platform still lists — and image discovery's probes, newest first, with the outcome, when, and a failure's reason taken while the job still existed. Use it when a job has vanished from list_headless_jobs, or to see why a probe failed an hour ago.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "limit": { "type": "integer", "minimum": 1, "maximum": 50, "description": "How many (default 20)." },
            "failedOnly": { "type": "boolean", "description": "Only the failures." }
          },
          "additionalProperties": false
        }
        """#
    )

    let jobs: @Sendable () async -> [JobRecord]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let all = await jobs().filter { args.failedOnly != true || $0.outcome == .failed }
        let limit = min(max(args.limit ?? 20, 1), JobHistoryStore.maxJobs)
        return Output(total: all.count, jobs: all.prefix(limit).map(Entry.init))
    }
}
