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
        /// Paused by someone, until they resume it (plan 40).
        let paused: Int
        let failed: Int
        /// The bar's one line.
        let summary: String
        /// Newest first.
        let tasks: [Entry]
    }

    struct Entry: Encodable, Sendable, Equatable {
        /// The task's id: what pause_activity and resume_activity take.
        let id: Int
        /// discovery, launch, session, compute, storage, download or research.
        let kind: String
        let label: String
        /// person, assistant or app — who set it going.
        let startedBy: String
        /// It repeats a task of the same name that failed.
        let again: Bool
        /// running, paused, succeeded, failed or cancelled (abandoned before it finished).
        let status: String
        let stage: String?
        /// How far it has got, when it counts: `done` of `total` (plan 40).
        var done: Int?
        var total: Int?
        /// It can be paused and resumed (pause_activity, resume_activity).
        var pausable: Bool?
        /// Who paused it — person, assistant or app — and why, while it is paused.
        var pausedBy: String?
        var pausedWhy: String?
        var pausedAt: String?
        /// A failure's reason, or a success's note.
        let message: String?
        let startedAt: String
        let finishedAt: String?
        let seconds: Int
        /// A running task's request still waiting, in words: "the CADC
        /// archive search had waited 58 s of its 120 s" (plan 23 L6).
        var waitingOn: String?
        /// What its requests to CADC and CANFAR came to.
        var requests: Requests?

        struct Requests: Encodable, Sendable, Equatable {
            let count: Int
            let failed: Int
            /// Seconds spent waiting on them, together.
            let seconds: Double
        }

        init(_ task: TrackedTask, now: Date, requests records: [RequestLedger.Record] = []) {
            let iso = ISO8601DateFormatter()
            id = task.id
            kind = task.kind.rawValue
            label = task.label
            startedBy = task.startedBy.rawValue
            again = task.isAgain
            status = task.progress.rawValue
            stage = task.stage.isEmpty ? nil : task.stage
            done = task.done
            total = task.total
            pausable = task.canPause && !task.isFinished ? true : nil
            if task.isPaused, let pause = task.pause {
                pausedBy = pause.by.rawValue
                pausedWhy = pause.cause.why
                pausedAt = iso.string(from: pause.at)
            }
            message = task.message
            startedAt = iso.string(from: task.started)
            finishedAt = task.finished.map(iso.string(from:))
            seconds = Int(task.elapsed(now: now))
            let mine = records.filter { $0.cause.task == task.id }
            waitingOn = task.isFinished ? nil : mine.last { !$0.isFinished }?.waitingSentence(now: now)
            requests = mine.isEmpty ? nil : Requests(
                count: mine.count, failed: mine.filter { $0.outcome?.isFailure == true }.count,
                seconds: (mine.map { $0.seconds(now: now) }.reduce(0, +) * 10).rounded() / 10)
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_activity",
        description: "What the app is doing — the activity bar at the bottom of the window: its slow work (image probes, launches, session actions, Storage transfers, downloads, remote-compute runs), newest first, each with who started it (`startedBy`: the person, an assistant — you or another — or the app itself), its `id`, its stage while running (\"Waiting for job …\") and, when it counts, how far it has got (`done` of `total`), how long it has taken, and a failure's reason. A task that can wait is `pausable`; a paused one says who paused it and why (`pausedBy`, `pausedWhy`) — pause_activity and resume_activity take its `id`; a running task's `waitingOn` names the request to CADC or CANFAR it waits on and how long of its timeout, and `requests` says what its requests came to. Finished work stays until the person clears it, so a failure from a sheet closed long ago can still be read. For everything that happened while you are connected, with why, read get_session_log. Read-only.",
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
    /// The requests sent lately and those waiting, to tell each task's.
    var requests: @Sendable () -> [RequestLedger.Record] = { RequestLedger.shared.recent() + RequestLedger.shared.waiting() }

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let all = await tasks()
        let now = Date()
        let limit = min(max(args.limit ?? 20, 1), TaskRegistry.maxTasks)
        let records = requests()
        return Output(running: all.filter { $0.progress == .running }.count, paused: all.filter(\.isPaused).count,
                      failed: all.filter(\.wentWrong).count,
                      summary: ActivitySummary.line(all),
                      tasks: all.reversed().prefix(limit).map { Entry($0, now: now, requests: records) })
    }
}
