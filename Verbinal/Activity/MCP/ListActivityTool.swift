// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `list_activity` — the activity bar, read: what the app is doing and
/// what went wrong, so an agent can tell a slow probe from a stuck one.
struct ListActivityTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        var limit: Int?
    }

    struct Output: Encodable, Sendable {
        let running: Int
        let failed: Int
        /// The bar's one line.
        let summary: String
        /// Newest first.
        let tasks: [Entry]
    }

    struct Entry: Encodable, Sendable, Equatable {
        /// discovery, launch, session, compute, storage, download or research.
        let kind: String
        let label: String
        /// person, assistant or app — who set it going.
        let startedBy: String
        /// running, succeeded, failed or cancelled (abandoned before it finished).
        let status: String
        let stage: String?
        /// A failure's reason, or a success's note.
        let message: String?
        let startedAt: String
        let finishedAt: String?
        let seconds: Int

        init(_ task: TrackedTask, now: Date) {
            let iso = ISO8601DateFormatter()
            kind = task.kind.rawValue
            label = task.label
            startedBy = task.startedBy.rawValue
            status = task.progress.rawValue
            stage = task.stage.isEmpty ? nil : task.stage
            message = task.message
            startedAt = iso.string(from: task.started)
            finishedAt = task.finished.map(iso.string(from:))
            seconds = Int(task.elapsed(now: now))
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_activity",
        description: "What the app is doing — the activity bar at the bottom of the window: its slow work (image probes, launches, session actions, Storage transfers, downloads, remote-compute runs), newest first, each with who started it (`startedBy`: the person, an assistant — you or another — or the app itself), its stage while running (\"Waiting for job …\"), how long it has taken, and a failure's reason. Finished work stays until the person clears it, so a failure from a sheet closed long ago can still be read. Read-only.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "limit": { "type": "integer", "minimum": 1, "maximum": 60, "description": "How many (default 20)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let tasks: @Sendable () async -> [TrackedTask]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let all = await tasks()
        let now = Date()
        let limit = min(max(args.limit ?? 20, 1), TaskRegistry.maxTasks)
        return Output(running: all.filter { !$0.isFinished }.count, failed: all.filter(\.wentWrong).count,
                      summary: ActivitySummary.line(all),
                      tasks: all.reversed().prefix(limit).map { Entry($0, now: now) })
    }
}
