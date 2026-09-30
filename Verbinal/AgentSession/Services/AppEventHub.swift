// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Everything that happens in the app while an assistant is connected,
/// told to each open session's log (plan 23 L2). It hears the request
/// ledger, the change and decision logs, the proposals' event log, the
/// activity bar and the sign-in through the observers each offers — none
/// of them knows it is here — and the MCP bridge through
/// `AgentSessionRecorder`. It is the one place those sources meet the
/// journals (orthogonality).
///
/// Events arrive on the threads they happen on and are taken, in order,
/// off one stream — the bridge's too, so a decision taken during a call is
/// told before the call's end.
actor AppEventHub: AgentSessionRecorder {
    /// A session's header, from the app's state when it opens.
    typealias HeaderSource = @Sendable (_ session: UUID, _ client: String) async -> SessionLogHeader

    enum Event: Sendable {
        case request(RequestLedger.Event)
        case change(Change)
        case decision(Decision)
        case proposal(AgentEventEntry)
        case task(TrackedTask)
        case auth(AuthLifecycleController.Event)
        // The bridge's.
        case opened(UUID, client: String)
        case callBegan(UUID, call: UUID)
        case callEnded(UUID, call: UUID, tool: String, traced: AIToolRouter.Traced)
        case closed(UUID)
        /// Nothing: every event before it has been told (`settle`).
        case settled
    }

    /// An event, and who waits for it to be told.
    private struct Queued: Sendable {
        let event: Event
        var done: CheckedContinuation<Void, Never>?
    }

    /// The sources, by the observers each offers (interface segregation).
    struct Sources: Sendable {
        var requests: RequestLedger = .shared
        var changes: ChangeLog = .shared
        var decisions: DecisionLog = .shared
        var proposals: Observers<AgentEventEntry>?
        var tasks: Observers<TrackedTask>?
        var auth: Observers<AuthLifecycleController.Event>?
    }

    let store: SessionLogStore
    private let header: HeaderSource
    private(set) var journals: [UUID: SessionJournal] = [:]
    private var clients: [UUID: String] = [:]
    /// Each proposal's summary and session, as its call or decision said.
    private var proposals: [UUID: (summary: String, session: UUID?)] = [:]
    private let events: AsyncStream<Queued>.Continuation

    init(store: SessionLogStore = SessionLogStore(), sources: Sources, header: @escaping HeaderSource) {
        self.store = store
        self.header = header
        let (stream, continuation) = AsyncStream.makeStream(of: Queued.self)
        self.events = continuation
        sources.requests.observe { continuation.yield(Queued(event: .request($0))) }
        sources.changes.observe { continuation.yield(Queued(event: .change($0))) }
        sources.decisions.observers.observe { continuation.yield(Queued(event: .decision($0))) }
        sources.proposals?.observe { continuation.yield(Queued(event: .proposal($0))) }
        sources.tasks?.observe { continuation.yield(Queued(event: .task($0))) }
        sources.auth?.observe { continuation.yield(Queued(event: .auth($0))) }
        Task { [weak self] in
            for await queued in stream {
                await self?.handle(queued.event)
                queued.done?.resume()
            }
        }
    }

    /// At launch: sessions a quit left open are closed, and old logs go.
    func start() {
        store.closeAbandoned(open: Set(journals.keys))
        store.applyRetention(open: Set(journals.keys))
    }

    func journal(for session: UUID) -> SessionJournal? { journals[session] }
    var openSessions: Set<UUID> { Set(journals.keys) }
    func client(of session: UUID) -> String? { clients[session] }

    // MARK: - The bridge

    func opened(_ session: UUID, client: String) async { await submit(.opened(session, client: client)) }
    func callBegan(_ session: UUID, call: UUID, tool: String) async { await submit(.callBegan(session, call: call)) }
    func callEnded(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) async {
        await submit(.callEnded(session, call: call, tool: tool, traced: traced))
    }
    func closed(_ session: UUID) async { await submit(.closed(session)) }

    /// Waits until every event before now is told — for tests.
    func settle() async { await submit(.settled) }

    /// Queues `event` and waits until it is told.
    private func submit(_ event: Event) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            events.yield(Queued(event: event, done: done))
        }
    }

    private func open(_ session: UUID, client: String) async {
        let header = await header(session, client)
        let journal = SessionJournal(header: header, store: store)
        await journal.record(SessionLogLine.opened(header))
        for other in journals.values { await other.record(SessionLogLine.assistantArrived(client, session: session)) }
        journals[session] = journal
        clients[session] = client
    }

    private func end(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) async {
        guard let journal = journals[session] else { return }
        if let proposal = traced.result.proposal { proposals[proposal.id] = (proposal.summary, session) }
        await journal.record(SessionLogLine.call(tool: tool, call: call, session: session, traced: traced))
        await journal.callEnded(call)
    }

    private func close(_ session: UUID) async {
        guard let journal = journals.removeValue(forKey: session) else { return }
        await journal.close(.disconnected)
        let client = clients.removeValue(forKey: session) ?? "an assistant"
        for other in journals.values { await other.record(SessionLogLine.assistantLeft(client, session: session)) }
        store.applyRetention(open: Set(journals.keys))
    }

    // MARK: - Telling the journals

    private func handle(_ event: Event) async {
        switch event {
        case .opened(let session, let client): await open(session, client: client)
        case .callBegan(let session, let call): await journals[session]?.callBegan(call)
        case .callEnded(let session, let call, let tool, let traced): await end(session, call: call, tool: tool, traced: traced)
        case .closed(let session): await close(session)
        case .settled: break
        default: await tell(event)
        }
    }

    private func tell(_ event: Event) async {
        for journal in journals.values {
            let seen = SessionViewpoint(session: journal.session, clients: clients)
            if let entry = await entry(for: event, in: journal, seen: seen) { await journal.record(entry) }
        }
    }

    private func entry(for event: Event, in journal: SessionJournal, seen: SessionViewpoint) async -> SessionLogEntry? {
        switch event {
        case .request(.finished(let record)):
            // A failure: the call it belongs to tells it, while under way.
            guard let outcome = record.outcome, outcome.isFailure, outcome != .cancelled else { return nil }
            if record.cause.session == journal.session, await journal.isInFlight(record.cause.call) { return nil }
            return SessionLogLine.request(record, seen: seen)
        case .request(.serviceFailing(let service, let last)):
            return SessionLogLine.serviceFailing(service, last)
        case .request(.serviceRecovered(let service, let record)):
            return SessionLogLine.serviceRecovered(service, record)
        case .request(.started):
            return nil
        case .change(let change):
            return SessionLogLine.action(change, seen: seen)
        case .decision(let decision):
            if let id = decision.cause.proposal, let subject = decision.subject {
                proposals[id] = (subject, decision.cause.session)
            }
            return SessionLogLine.decision(decision, seen: seen)
        case .proposal(let event):
            let known = event.event.proposalID.flatMap { proposals[$0] }
            return SessionLogLine.proposal(event, subject: known?.summary, ours: known?.session == journal.session)
        case .task(let task):
            return SessionLogLine.task(task, seen: seen)
        case .auth(.signedIn(let username)):
            return SessionLogLine.signedIn(username)
        case .auth(.signedOut):
            return SessionLogLine.signedOut()
        case .opened, .callBegan, .callEnded, .closed, .settled:
            return nil
        }
    }
}

extension AgentEvent {
    /// The proposal it is about.
    var proposalID: UUID? {
        switch self {
        case .proposalArrived(let id, _, _), .proposalApplied(let id, _, _), .proposalRejected(let id, _),
             .proposalWithdrawn(let id, _), .proposalFailed(let id, _), .proposalExpired(let id, _):
            id
        }
    }
}
