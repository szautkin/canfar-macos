// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// Why work is being done, and what it belongs to. It travels with the
/// work as a task-local, beside `Initiator` (who), and is set once where
/// work enters — the router for a call, the apply of a proposal, an app
/// rule — so whatever records the work (a change, a request, a task) says
/// why without anyone passing it by hand, and none can forget (plan 23 K).
public struct Cause: Codable, Sendable, Equatable {
    /// In words: an assistant's reason, or the app's rule. `nil` for the
    /// person's own work, and for an assistant that gave none.
    public var why: String?
    /// The assistant session the work belongs to.
    public var session: UUID?
    /// The tool call that set it going (`AIToolContext.requestID`).
    public var call: UUID?
    /// The proposal being applied.
    public var proposal: UUID?
    /// Who applied that proposal: the person from Pending, auto-apply, or
    /// an assistant's background start.
    public var appliedBy: ApplyActor?

    public init(why: String? = nil, session: UUID? = nil, call: UUID? = nil,
                proposal: UUID? = nil, appliedBy: ApplyActor? = nil) {
        self.why = Self.clip(why)
        self.session = session
        self.call = call
        self.proposal = proposal
        self.appliedBy = appliedBy
    }

    /// The work under way's cause. None — the person's own — unless a
    /// caller says otherwise. A `Task` inherits it; a detached one takes it
    /// explicitly, as it does `Initiator` (plan 19 T2).
    @TaskLocal public static var current = Cause()

    /// Applying `proposal`: its assistant's reason and call, and who applied it.
    public static func applying(_ proposal: PendingProposal, by actor: ApplyActor) -> Cause {
        Cause(why: proposal.why, session: proposal.session, call: proposal.requestID,
              proposal: proposal.id, appliedBy: actor)
    }

    /// A reason's longest: a sentence, not a payload.
    public static let maxWhy = 200

    /// Trimmed, `nil` when empty, cut at `maxWhy`.
    public static func clip(_ why: String?) -> String? {
        guard let trimmed = why?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > maxWhy ? String(trimmed.prefix(maxWhy - 1)) + "…" : trimmed
    }

    /// The argument every write tool takes, as the manifest publishes it.
    public static let argumentName = "why"
    public static let argumentSchema = JSONValue.object([
        "type": .string("string"),
        "maxLength": .int(maxWhy),
        "description": .string("Why you are making this change, in one sentence. The person reads it with the change in Pending, above all before a delete, and the session log keeps it with the change. Give one with every change."),
    ])

    /// `schema` with `why` among its properties, when `verbClass` proposes
    /// a change: every write tool takes it, and no tool declares it itself
    /// (open–closed).
    public static func publishing(_ schema: JSONValue, for verbClass: VerbClass) -> JSONValue {
        guard verbClass.proposesChange, case .object(var root) = schema else { return schema }
        var properties: [String: JSONValue] = [:]
        if case .object(let declared)? = root["properties"] { properties = declared }
        properties[argumentName] = argumentSchema
        root["properties"] = .object(properties)
        return .object(root)
    }

    /// Takes `why` off a call's arguments — it is the router's, not the
    /// tool's — and answers the arguments without it, and the reason.
    public static func take(from arguments: Data) -> (arguments: Data, why: String?) {
        guard !arguments.isEmpty,
              var object = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any],
              let value = object.removeValue(forKey: argumentName) else {
            return (arguments, nil)
        }
        let rest = (try? JSONSerialization.data(withJSONObject: object)) ?? arguments
        return (rest, clip(value as? String))
    }
}
