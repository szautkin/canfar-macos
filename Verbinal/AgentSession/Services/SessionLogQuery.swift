// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What is happening in the app right now, for a session: the requests
/// still waiting, the tasks running, the proposals waiting and why, the
/// services failing, the sign-in (plan 23 L3). The app builds it from its
/// live state; the log holds the past.
struct SessionNow: Codable, Sendable, Equatable {
    struct Waiting: Codable, Sendable, Equatable {
        let service: String
        let name: String
        let seconds: Double
        let timeout: Double
        let startedBy: String
        /// "the CADC archive search had waited 58 s of its 120 s".
        let line: String
    }
    struct Running: Codable, Sendable, Equatable {
        let task: Int
        let label: String
        let stage: String?
        let seconds: Double
        let startedBy: String
        /// The request it is waiting on, in words.
        let waitingOn: String?
    }
    struct Pending: Codable, Sendable, Equatable {
        let proposal: String
        let summary: String
        let why: String?
        /// "waits in Pending: a delete always waits for the person".
        let waits: String
    }

    let requestsWaiting: [Waiting]
    let tasksRunning: [Running]
    let proposalsWaiting: [Pending]
    let servicesFailing: [String]
    let signedIn: Bool
}

/// Reading a session's log — the one reader behind the assistant's three
/// tools and the person's view (plan 23 L3, DRY): which entries, filtered,
/// with the tasks a change already tells folded away, summarised, and one
/// entry's chain of cause and effect.
struct SessionLogQuery: Sendable {
    let store: SessionLogStore
    let hub: AppEventHub

    /// A session's header and entries — the open journal's, or its file's.
    func log(of session: UUID) async -> (header: SessionLogHeader, entries: [SessionLogEntry], open: Bool)? {
        if let journal = await hub.journal(for: session) {
            return (journal.header, await journal.entries, true)
        }
        guard let url = store.url(of: session), let (header, entries) = store.read(url) else { return nil }
        return (header, entries, false)
    }

    /// The session a reader named: a whole id or its first characters.
    func session(named raw: String) async -> UUID? {
        let wanted = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if let id = UUID(uuidString: wanted) { return id }
        guard wanted.count >= 4 else { return nil }
        let known = Array(await hub.openSessions) + store.list().map(\.header.session)
        return known.first { $0.uuidString.hasPrefix(wanted) }
    }

    // MARK: - Filtering

    struct Filter: Sendable {
        var only: String?
        var who: String?
        var about: String?
        var text: String?
        var from: Date?
        var to: Date?
    }

    static func filter(_ entries: [SessionLogEntry], _ filter: Filter) -> [SessionLogEntry] {
        entries.filter { entry in
            if let only = filter.only, !matches(entry, only: only) { return false }
            if let who = filter.who, entry.who?.rawValue != who { return false }
            if let about = filter.about?.trimmingCharacters(in: .whitespaces), !about.isEmpty,
               !isAbout(entry, about) { return false }
            if let text = filter.text, !text.isEmpty, entry.line.range(of: text, options: .caseInsensitive) == nil { return false }
            if let from = filter.from, entry.at < from { return false }
            if let to = filter.to, entry.at > to { return false }
            return true
        }
    }

    static func matches(_ entry: SessionLogEntry, only: String) -> Bool {
        switch only {
        case "actions": entry.kind == .action
        case "failures": entry.isFailure || entry.kind == .request || entry.outcome == "failing"
        case "decisions": entry.kind == .decision
        case "calls": entry.kind == .call
        case "tasks": entry.kind == .task
        case "proposals": entry.kind == .proposal || (entry.kind == .decision && entry.ids.proposal != nil)
        case "requests": entry.kind == .request || entry.requests?.isEmpty == false
        case "app": entry.kind == .app || entry.kind == .opened || entry.kind == .closed
        default: true
        }
    }

    /// Everything about one thing: an id or its start, a task's number, a
    /// tool, a service, or words of the line (a file's name).
    static func isAbout(_ entry: SessionLogEntry, _ about: String) -> Bool {
        let upper = about.uppercased()
        let ids = [entry.ids.session, entry.ids.call, entry.ids.proposal].compactMap { $0?.uuidString }
        if about.count >= 4, ids.contains(where: { $0.hasPrefix(upper) }) { return true }
        if let task = entry.ids.task, about == "\(task)" || about == "task \(task)" { return true }
        if entry.tool == about || entry.codes?.tag == about { return true }
        if entry.requests?.contains(where: { $0.service == about }) == true { return true }
        return entry.line.range(of: about, options: .caseInsensitive) != nil
    }

    /// Without the task entries a change already tells: the task that
    /// tracked it, and one run in applying its proposal. `explain` keeps them.
    static func folded(_ entries: [SessionLogEntry]) -> [SessionLogEntry] {
        let actions = entries.filter { $0.kind == .action }
        let tasks = Set(actions.compactMap(\.ids.task))
        let proposals = Set(actions.compactMap(\.ids.proposal))
        return entries.filter { entry in
            guard entry.kind == .task else { return true }
            if let task = entry.ids.task, tasks.contains(task) { return false }
            if let proposal = entry.ids.proposal, proposals.contains(proposal) { return false }
            return true
        }
    }

    // MARK: - Summary

    struct Summary: Codable, Sendable, Equatable {
        struct Actions: Codable, Sendable, Equatable {
            let done: Int
            let failed: Int
            /// assistant, anotherAssistant, person, app.
            let byWho: [String: Int]
        }
        struct Slowest: Codable, Sendable, Equatable {
            let service: String
            let seconds: Double
            let outcome: String
            let token: Int
        }
        let actions: Actions
        let calls: Int
        let callsFailed: Int
        /// Seconds spent waiting on each service, by id.
        let secondsByService: [String: Double]
        let slowestRequest: Slowest?
        let decisionsByRule: [String: Int]
    }

    static func summary(_ entries: [SessionLogEntry]) -> Summary {
        let actions = entries.filter { $0.kind == .action }
        let calls = entries.filter { $0.kind == .call }
        var seconds: [String: Double] = [:]
        var slowest: Summary.Slowest?
        for entry in entries {
            for request in entry.requests ?? [] {
                seconds[request.service, default: 0] += request.seconds
                if request.seconds > (slowest?.seconds ?? -1) {
                    slowest = .init(service: request.name, seconds: request.seconds, outcome: request.outcome, token: entry.token)
                }
            }
        }
        return Summary(
            actions: .init(done: actions.filter { $0.outcome == "done" }.count,
                           failed: actions.filter { $0.outcome == "failed" }.count,
                           byWho: Dictionary(grouping: actions, by: { $0.who?.rawValue ?? "unknown" }).mapValues(\.count)),
            calls: calls.count, callsFailed: calls.filter(\.isFailure).count,
            secondsByService: seconds, slowestRequest: slowest,
            decisionsByRule: Dictionary(grouping: entries.filter { $0.kind == .decision },
                                        by: { $0.outcome ?? "unknown" }).mapValues(\.count))
    }

    // MARK: - Cause and effect

    struct Explanation: Codable, Sendable, Equatable {
        let entry: SessionLogEntry
        /// What led to it, oldest first.
        let causes: [SessionLogEntry]
        /// What it led to, in order.
        let effects: [SessionLogEntry]
        /// The chain, in plain sentences, with times.
        let story: String
    }

    /// `token`'s entry and its chain: linked by call, proposal and task.
    static func explain(_ token: Int, in entries: [SessionLogEntry]) -> Explanation? {
        guard let entry = entries.first(where: { $0.token == token }) else { return nil }
        let others = entries.filter { $0.token != token }
        // The call that started it; the call that proposed it; the decision
        // about its proposal; the task it ran in.
        let causes = others.filter { other in
            if other.kind == .call, let call = entry.ids.call, other.ids.call == call, entry.kind != .call { return true }
            if other.kind == .call, let proposal = entry.ids.proposal, other.ids.proposal == proposal, entry.kind != .call { return true }
            if other.kind == .decision, let proposal = entry.ids.proposal, other.ids.proposal == proposal,
               entry.kind == .action || entry.kind == .proposal { return true }
            if other.kind == .task, other.outcome == "running", let task = entry.ids.task, other.ids.task == task,
               entry.kind != .task { return true }
            return false
        }
        // What it set going: all that shares its call, its proposal, its task —
        // by link, not by place: a call's entry is written when it ends,
        // after the decisions it led to.
        let effects = others.filter { other in
            guard !causes.contains(other), other.kind != .opened else { return false }
            if let call = entry.ids.call, entry.kind == .call, other.ids.call == call { return true }
            if let proposal = entry.ids.proposal, other.ids.proposal == proposal { return true }
            if let task = entry.ids.task, other.ids.task == task { return true }
            return false
        }
        let chain = causes + [entry] + effects
        return Explanation(entry: entry, causes: causes, effects: effects,
                           story: chain.map(SessionLogLine.timed).joined(separator: " → "))
    }
}
