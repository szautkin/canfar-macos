// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A change to the person's work — something created, launched,
/// downloaded, deleted — as the session log tells it: what, by whom, why,
/// and how it ended (plan 23 C).
public struct Change: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case done
        case failed
        /// Stopped before it finished.
        case cancelled
    }

    public let id: UUID
    /// The kind of change, as a proposal names it: `delete_session`.
    public let kind: String
    /// Past tense: "deleted".
    public let verb: String
    /// What it acted on, in words: "session qa-person (q9p87ajc)".
    public let what: String
    public let startedBy: Initiator
    /// Why, and what it belongs to.
    public let cause: Cause
    public let started: Date
    public let finished: Date
    public let outcome: Outcome
    /// Why it failed, in words.
    public let failure: String?
    /// The activity bar's task that tracked it, if one did.
    public let task: Int?

    public var seconds: Double { finished.timeIntervalSince(started) }

    /// "Deleted session qa-person (q9p87ajc)".
    public var sentence: String {
        let head = verb.prefix(1).uppercased() + verb.dropFirst()
        return what.isEmpty ? String(head) : "\(head) \(what)"
    }
}

/// Where every change is recorded, once, by the one that makes it
/// (plan 23 C):
///
/// - **an assistant's change** where its proposal is applied — the one
///   apply path — with the proposal's summary, why and who applied it
///   (`applying`);
/// - **the person's and the app's** by the owner that makes the change —
///   the service or store both the screen and the applier call (`run`,
///   `done`). Inside an apply the owner does not record it again.
///
/// The log keeps no history of its own: observers — the session journal —
/// keep what they need. Shared by default, as a cross-cutting log is; a
/// test hands in its own.
public final class ChangeLog: Sendable {
    public static let shared = ChangeLog()

    public let observers = Observers<Change>()

    public init() {}

    // MARK: - Recording

    /// Runs a change of `kind` to `what` and records how it ended — unless
    /// it is part of an assistant's proposal being applied, which the apply
    /// records.
    public func run<T>(_ kind: String, _ what: String, task: Int? = nil,
                       _ work: () async throws -> T) async rethrows -> T {
        guard Cause.current.proposal == nil else { return try await work() }
        return try await measure(kind, what, cause: Cause.current, task: task, work)
    }

    /// A change made — at once, or since `started`.
    public func done(_ kind: String, _ what: String, since started: Date = Date(), task: Int? = nil) {
        guard Cause.current.proposal == nil else { return }
        emit(kind, what, cause: Cause.current, started: started, outcome: .done, failure: nil, task: task)
    }

    /// A change that could not be made, and why.
    public func failed(_ kind: String, _ what: String, because failure: String,
                       since started: Date = Date(), task: Int? = nil) {
        guard Cause.current.proposal == nil else { return }
        emit(kind, what, cause: Cause.current, started: started, outcome: .failed, failure: failure, task: task)
    }

    /// Applies an assistant's `proposal` — `work` runs under its cause —
    /// and records the change: its summary, its why, who applied it.
    public func applying<T>(_ proposal: PendingProposal, by actor: ApplyActor,
                            _ work: () async throws -> T) async rethrows -> T {
        let cause = Cause.applying(proposal, by: actor)
        return try await Cause.$current.withValue(cause) {
            try await measure(proposal.kind, ChangeVerb.object(of: proposal.summary, kind: proposal.kind),
                              cause: cause, task: nil, work)
        }
    }

    private func measure<T>(_ kind: String, _ what: String, cause: Cause, task: Int?,
                            _ work: () async throws -> T) async rethrows -> T {
        let started = Date()
        do {
            let result = try await work()
            emit(kind, what, cause: cause, started: started, outcome: .done, failure: nil, task: task)
            return result
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            emit(kind, what, cause: cause, started: started, outcome: cancelled ? .cancelled : .failed,
                 failure: cancelled ? nil : Self.words(error), task: task)
            throw error
        }
    }

    private func emit(_ kind: String, _ what: String, cause: Cause, started: Date,
                      outcome: Change.Outcome, failure: String?, task: Int?) {
        let change = Change(id: UUID(), kind: kind, verb: ChangeVerb.of(kind: kind) ?? ChangeVerb.fallback,
                            what: what, startedBy: Initiator.current, cause: cause, started: started,
                            finished: Date(), outcome: outcome, failure: failure, task: task ?? cause.task)
        observers.notify(change)
    }

    /// An error in words: the apply's own message, the error's description.
    static func words(_ error: Error) -> String {
        if let apply = error as? ProposalApplyError { return apply.message }
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        return error.localizedDescription
    }

    // MARK: - Observing

    /// Calls `observer` with every change until `stopObserving`.
    @discardableResult
    public func observe(_ observer: @escaping @Sendable (Change) -> Void) -> UUID {
        observers.observe(observer)
    }

    public func stopObserving(_ id: UUID) {
        observers.stopObserving(id)
    }
}

/// The verbs of change, from a kind's own words — data, not branches: a
/// new kind of change needs, at most, a row (ETC). A test fails when a
/// registered kind has no verb here.
public enum ChangeVerb {
    /// Imperative → past tense.
    public static let table: [String: String] = [
        "add": "added", "apply": "applied", "cancel": "cancelled", "change": "changed", "clear": "cleared", "copy": "copied",
        "correct": "corrected", "create": "created", "delete": "deleted", "discover": "inspected",
        "download": "downloaded", "export": "exported", "launch": "launched", "make": "made",
        "mkdir": "made", "move": "moved", "open": "opened", "remove": "removed", "rename": "renamed",
        "renew": "renewed", "request": "requested", "run": "ran", "save": "saved", "set": "set",
        "start": "started", "stop": "stopped", "update": "updated", "upload": "uploaded", "use": "used",
    ]

    /// When a kind has no verb in the table.
    public static let fallback = "changed"

    /// "deleted" for `delete_session`, "updated" for
    /// `bulk_update_observation_notes`, "made" for `vospace_mkdir`: the
    /// first of the kind's words that is a verb.
    public static func of(kind: String) -> String? {
        kind.lowercased().split(separator: "_").lazy.compactMap { table[String($0)] }.first
    }

    /// A proposal's summary as the object of its verb: "Delete session x"
    /// → "session x". A summary that does not start with its verb is kept.
    public static func object(of summary: String, kind: String) -> String {
        let words = summary.split(separator: " ", maxSplits: 1)
        guard let first = words.first, words.count == 2,
              let past = table[first.lowercased()], past == of(kind: kind) else { return summary }
        return String(words[1])
    }
}
