// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `pause_activity` and `resume_activity` (plan 40): an assistant pauses
/// work on the activity bar that can wait — the storage sync — and resumes
/// it, as the person does with the bar's Pause and Resume. Live and
/// reversible, so no proposal; the bar says who paused it, and the session
/// log keeps who and the `reason`.
struct PauseActivityTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        /// The task's id, from list_activity.
        let id: Int
        /// Why, in a sentence — not `why`, which only a proposed change takes.
        var reason: String?
    }

    struct Output: Encodable, Sendable {
        /// The task as it stands now.
        let task: ListActivityTool.Entry
    }

    let definition: AIToolDefinition
    let act: @Sendable (Args) async throws -> ListActivityTool.Entry

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        Output(task: try await act(args))
    }

    private static func schema(_ verb: String) -> String {
        """
        {
          "type": "object",
          "properties": {
            "id": { "type": "integer", "description": "The task's id, from list_activity." },
            "reason": { "type": "string", "maxLength": \(Cause.maxWhy), "description": "Why you \(verb) it, in one sentence: the session log keeps it." }
          },
          "required": ["id"],
          "additionalProperties": false
        }
        """
    }

    static func pause(registry: TaskRegistry) -> Self {
        Self(definition: .withStaticSchema(
            name: "pause_activity",
            description: "Pause a task on the activity bar that can wait — `pausable` in list_activity, such as the storage sync — where it is, as the person's Pause on the bar does. It stays paused, through relaunches, until someone resumes it (resume_activity); while it is paused nothing of it runs. The bar says it was paused by your assistant. Live and reversible: no proposal. Answers the task as it now stands.",
            schema: schema("pause")),
             act: { args in try await act(registry, args, pause: true) })
    }

    static func resume(registry: TaskRegistry) -> Self {
        Self(definition: .withStaticSchema(
            name: "resume_activity",
            description: "Resume a paused task on the activity bar — the person's or yours — as the person's Resume does: it goes on from where it stopped. A task the person paused was their choice: resume it only when they ask. Live: no proposal. Answers the task as it now stands.",
            schema: schema("resume")),
             act: { args in try await act(registry, args, pause: false) })
    }

    private static func act(_ registry: TaskRegistry, _ args: Args, pause: Bool) async throws -> ListActivityTool.Entry {
        let initiator = Initiator.current
        return try await MainActor.run {
            let refusal = pause ? registry.pause(args.id, by: initiator, why: args.reason)
                                : registry.resume(args.id, by: initiator, why: args.reason)
            if let refusal {
                throw registry.task(args.id) == nil ? ToolFailureReason.unknownTarget(refusal)
                                                    : ToolFailureReason.invalidArgument(refusal)
            }
            guard let task = registry.task(args.id) else { throw ToolFailureReason.unknownTarget("No task \(args.id).") }
            return ListActivityTool.Entry(task, now: Date())
        }
    }
}
