// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Who is reading a session's log: the session, and the other sessions'
/// clients — to say "by the assistant" of this session's own work and
/// "by another assistant (claude-code/2.1)" of another's.
struct SessionViewpoint: Sendable {
    let session: UUID
    var clients: [UUID: String] = [:]

    func who(_ startedBy: Initiator, _ cause: Cause) -> (who: SessionLogEntry.Who, client: String?) {
        if cause.session == session { return (.assistant, nil) }
        switch startedBy {
        case .assistant: return (.anotherAssistant, cause.session.flatMap { clients[$0] })
        case .app: return (.app, nil)
        case .person: return (.person, nil)
        }
    }
}

/// Every entry of a session log, put into words — the one place: the
/// person's view, the text export and the assistant's tools all read the
/// sentence made here (plan 23 L2). Neutral words, since the person and
/// the assistant both read them: "by the assistant", "by the person".
enum SessionLogLine {

    // MARK: - Pieces

    static func by(_ who: SessionLogEntry.Who, client: String?) -> String {
        switch who {
        case .assistant: "by the assistant"
        case .anotherAssistant: client.map { "by another assistant (\($0))" } ?? "by another assistant"
        case .person: "by the person"
        case .app: "by Verbinal"
        }
    }

    /// ", applied by the person" — how a proposal was applied.
    static func applied(_ actor: ApplyActor?) -> String {
        switch actor {
        case .person?: ", applied by the person"
        case .autoApply?: ", applied at once by Auto-apply"
        case .background?: ", applied in the background"
        case nil: ""
        }
    }

    static func because(_ why: String?) -> String {
        why.map { ", because: \($0)" } ?? ""
    }

    static func time(_ seconds: Double) -> String { CallTiming.duration(seconds) }

    private static func entry(_ kind: SessionLogEntry.Kind, at: Date = Date(), _ line: String) -> SessionLogEntry {
        SessionLogEntry(token: 0, at: at, kind: kind, line: line)
    }

    // MARK: - Changes

    /// "Deleted session x — by the assistant, applied by the person,
    /// because: throwaway. Done in 2 s."
    static func action(_ change: Change, seen: SessionViewpoint) -> SessionLogEntry {
        let (who, client) = seen.who(change.startedBy, change.cause)
        let end: String
        switch change.outcome {
        case .done: end = "Done in \(time(change.seconds))."
        case .failed: end = "Failed after \(time(change.seconds)): \(change.failure ?? "no reason given")."
        case .cancelled: end = "Stopped after \(time(change.seconds))."
        }
        var entry = Self.entry(.action, at: change.finished,
                               "\(change.sentence) — \(by(who, client: client))\(applied(change.cause.appliedBy))\(because(change.cause.why)). \(end)")
        entry.who = who
        entry.client = client
        entry.why = change.cause.why
        entry.outcome = change.outcome.rawValue
        entry.seconds = change.seconds
        entry.tool = change.kind
        entry.ids = .init(session: change.cause.session, call: change.cause.call, proposal: change.cause.proposal,
                          task: change.task)
        return entry
    }

    // MARK: - Calls

    /// "Called search_observations — answered in 48 s. The CADC archive
    /// search answered in 47 s: slow, but it answered."
    static func call(tool: String, call: UUID, session: UUID, traced: AIToolRouter.Traced) -> SessionLogEntry {
        let timing = CallTiming(traced)
        let what: String
        let outcome: String
        var codes: SessionLogEntry.Codes?
        switch traced.result {
        case .data: (what, outcome) = ("answered", "answered")
        case .image: (what, outcome) = ("answered with an image", "answered")
        case .proposed(let proposal): (what, outcome) = ("proposed \"\(proposal.summary)\"", "proposed")
        case .failed(let reason):
            (what, outcome) = ("failed: \(ToolFailureReason.clip(reason.description, max: 300))", "failed")
            codes = .init(tag: reason.auditTag)
        }
        var entry = Self.entry(.call, "Called \(tool) — \(what), in \(time(traced.seconds)). \(timing.verdict)")
        entry.who = .assistant
        entry.outcome = outcome
        entry.seconds = traced.seconds
        entry.tool = tool
        entry.retry = timing.retry?.rawValue
        entry.ids = .init(session: session, call: call, proposal: traced.result.proposal?.id)
        entry.codes = codes
        entry.requests = timing.requests.isEmpty ? nil : timing.requests
        return entry
    }

    // MARK: - Tasks

    /// "Began: Inspect x — by the assistant." / "Inspect x succeeded in 3 min."
    static func task(_ task: TrackedTask, seen: SessionViewpoint) -> SessionLogEntry {
        let (who, client) = seen.who(task.startedBy, task.cause)
        let line: String
        switch task.progress {
        case .running: line = "Began: \(task.label) — \(by(who, client: client))\(because(task.cause.why))."
        case .succeeded: line = "\(task.label) succeeded in \(time(task.elapsed()))\(task.message.map { ": \($0)" } ?? "")."
        case .failed: line = "\(task.label) failed after \(time(task.elapsed())): \(task.message ?? "no reason given")."
        case .cancelled: line = "\(task.label) was abandoned after \(time(task.elapsed()))."
        }
        var entry = Self.entry(.task, at: task.finished ?? task.started, line)
        entry.who = who
        entry.client = client
        entry.why = task.cause.why
        entry.outcome = task.progress.rawValue
        entry.seconds = task.isFinished ? task.elapsed() : nil
        entry.ids = .init(session: task.cause.session, call: task.cause.call, proposal: task.cause.proposal, task: task.id)
        return entry
    }

    // MARK: - Proposals and decisions

    /// A proposal rejected, withdrawn or expired; nil for the events an
    /// action or a decision already tells.
    static func proposal(_ event: AgentEventEntry, subject: String?, ours: Bool) -> SessionLogEntry? {
        func name(_ id: UUID, _ kind: String) -> String {
            subject.map { "\"\($0)\"" } ?? "\(kind) \(id.uuidString.prefix(8))"
        }
        switch event.event {
        case .proposalRejected(let id, let kind):
            return tagged("The person rejected the proposal \(name(id, kind)).", "rejected", id, event.occurredAt, ours)
        case .proposalWithdrawn(let id, let kind):
            return tagged("The proposal \(name(id, kind)) was withdrawn by its assistant.", "withdrawn", id, event.occurredAt, ours)
        case .proposalExpired(let id, let kind):
            return tagged("The proposal \(name(id, kind)) expired: \(PendingProposal.expiryRule).", "expired", id, event.occurredAt, ours)
        case .proposalArrived, .proposalApplied, .proposalFailed:
            // Its decision says it arrived and why it waits; its action says
            // how it was applied.
            return nil
        }
    }

    private static func tagged(_ line: String, _ outcome: String, _ id: UUID, _ at: Date, _ ours: Bool) -> SessionLogEntry {
        var entry = Self.entry(.proposal, at: at, line)
        entry.who = ours ? .assistant : .anotherAssistant
        entry.outcome = outcome
        entry.ids.proposal = id
        return entry
    }

    /// "Verbinal decided: "Delete x" waits in Pending: a delete always waits for the person."
    static func decision(_ decision: Decision, seen: SessionViewpoint) -> SessionLogEntry {
        let (who, client) = seen.who(decision.startedBy, decision.cause)
        var entry = Self.entry(.decision, at: decision.at, "Verbinal decided: \(decision.sentence).")
        entry.who = who
        entry.client = client
        entry.why = decision.cause.why
        entry.outcome = decision.rule.rawValue
        entry.codes = .init(tag: decision.rule.rawValue)
        entry.ids = .init(session: decision.cause.session, call: decision.cause.call,
                          proposal: decision.cause.proposal, task: decision.cause.task)
        return entry
    }

    // MARK: - Requests and services

    /// "The CADC archive search did not answer in time — it is slow or
    /// down: a request by the person, after 120 s of its 120 s (URLError -1001)."
    static func request(_ record: RequestLedger.Record, seen: SessionViewpoint) -> SessionLogEntry {
        let (who, client) = seen.who(record.startedBy, record.cause)
        let outcome = record.outcome ?? .cancelled
        let code = record.code.map { " (\($0))" } ?? ""
        var entry = Self.entry(.request, at: record.finished ?? Date(),
                               "\(capitalized(record.service.name)) \(outcome.meaning): a request \(by(who, client: client)), after \(time(record.seconds())) of its \(Int(record.timeout)) s\(code).")
        entry.who = who
        entry.client = client
        entry.outcome = outcome.rawValue
        entry.seconds = record.seconds()
        entry.retry = outcome.retry?.rawValue
        entry.ids = .init(session: record.cause.session, call: record.cause.call, proposal: record.cause.proposal,
                          task: record.cause.task, request: record.id)
        entry.codes = .init(status: record.status, error: record.errorCode)
        return entry
    }

    static func serviceFailing(_ service: RequestService, _ last: RequestLedger.Record) -> SessionLogEntry {
        let code = last.code.map { " (\($0))" } ?? ""
        var entry = Self.entry(.app, "\(capitalized(service.name)) is failing: \(RequestLedger.failingAfter) failures in a row; the last \(last.outcome?.meaning ?? "failed")\(code).")
        entry.outcome = "failing"
        entry.ids.request = last.id
        entry.codes = .init(status: last.status, error: last.errorCode, tag: service.id)
        return entry
    }

    static func serviceRecovered(_ service: RequestService, _ record: RequestLedger.Record) -> SessionLogEntry {
        var entry = Self.entry(.app, "\(capitalized(service.name)) answers again.")
        entry.outcome = "recovered"
        entry.ids.request = record.id
        entry.codes = .init(tag: service.id)
        return entry
    }

    // MARK: - The app

    static func signedIn(_ username: String) -> SessionLogEntry {
        var entry = Self.entry(.app, "The person signed in as \(username).")
        entry.who = .person
        entry.outcome = "signedIn"
        return entry
    }

    static func signedOut() -> SessionLogEntry {
        var entry = Self.entry(.app, "The person signed out: everything that needs their CADC account waits for a sign-in.")
        entry.who = .person
        entry.outcome = "signedOut"
        return entry
    }

    static func assistantArrived(_ client: String, session: UUID) -> SessionLogEntry {
        var entry = Self.entry(.app, "Another assistant connected: \(client).")
        entry.who = .anotherAssistant
        entry.client = client
        entry.ids.session = session
        return entry
    }

    static func assistantLeft(_ client: String, session: UUID) -> SessionLogEntry {
        var entry = Self.entry(.app, "Another assistant left: \(client).")
        entry.who = .anotherAssistant
        entry.client = client
        entry.ids.session = session
        return entry
    }

    // MARK: - The handshake (plan 25)

    /// "The person allowed the session of Claude (claude-opus-5-5), here to
    /// …, with these instructions: …".
    static func started(_ approval: SessionApprovals.Approval) -> SessionLogEntry {
        let request = approval.request
        let model = request.model.map { " (\($0))" } ?? ""
        let purpose = request.purpose.map { ", here to: \($0)" } ?? ""
        let instructions = approval.instructions.isEmpty ? "no instructions" : "these instructions: \(approval.instructions)"
        var entry = Self.entry(.started, at: approval.allowedAt,
                               "The person allowed the session of \(request.agent)\(model), as the assistant presents itself\(purpose) — with \(instructions)")
        entry.who = .person
        entry.client = request.client
        entry.why = request.purpose
        entry.outcome = "allowed"
        entry.ids.session = request.id
        return entry
    }

    static func declined(_ request: SessionApprovals.Request) -> SessionLogEntry {
        var entry = Self.entry(.app, "The person declined the session of \(request.agent) (\(request.client)).")
        entry.who = .person
        entry.client = request.client
        entry.outcome = "declined"
        return entry
    }

    static func abandoned(_ request: SessionApprovals.Request) -> SessionLogEntry {
        var entry = Self.entry(.app, "\(request.agent) stopped waiting before the person answered its session.")
        entry.who = .assistant
        entry.outcome = "abandoned"
        return entry
    }

    // MARK: - The session

    static func opened(_ header: SessionLogHeader) -> SessionLogEntry {
        let commit = header.buildCommit.map { ", \($0)" } ?? ""
        var entry = Self.entry(.opened, at: header.opened,
                               "The assistant (\(header.client)) connected to Verbinal \(header.app)\(commit) on macOS \(header.macOS). Auto-apply is \(header.autoApply ? "on" : "off"); the person is \(header.signedIn ? "signed in" : "not signed in").")
        entry.who = .assistant
        entry.ids.session = header.session
        return entry
    }

    /// How a session ended.
    enum Ending: String, Sendable {
        case disconnected
        case verbinalQuit
    }

    static func closed(_ how: Ending, at: Date = Date()) -> SessionLogEntry {
        var entry = Self.entry(.closed, at: at, how == .disconnected
            ? "The assistant disconnected."
            : "Verbinal quit while the session was open.")
        entry.outcome = how.rawValue
        return entry
    }

    static func trimmed(_ count: Int) -> SessionLogEntry {
        var entry = Self.entry(.app, "\(count) older entries were dropped to keep this log within \(SessionLogRetention.maxSessionBytes / 1_048_576) MB; changes and decisions were kept longest.")
        entry.outcome = "trimmed"
        return entry
    }

    // MARK: - Reading

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// "14:02:07 Deleted session x — …": the view's and the text export's line.
    static func timed(_ entry: SessionLogEntry) -> String {
        "\(clock.string(from: entry.at)) \(entry.line)"
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension ToolResult {
    /// The proposal a call made, if it made one.
    var proposal: PendingProposal? {
        if case .proposed(let proposal) = self { return proposal }
        return nil
    }
}

extension PendingProposal {
    /// Why an unapplied proposal expires, in words (plan 15 S4).
    static let expiryRule = "a change not applied within 3 hours is not applied later, against a changed world"
}
