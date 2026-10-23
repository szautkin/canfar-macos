// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What the Portal puts first on iPhone and iPad: only what needs the
/// person, most pressing first (plan 47 1.2). Nothing here when all is well.
enum PortalAttention {
    /// A session as these rules read it.
    struct SessionFacts: Equatable, Sendable {
        let id: String
        let name: String
        let status: String
        let started: Date?
        let expires: Date?

        var isRunning: Bool { status.lowercased() == "running" }
        var isPending: Bool { status.lowercased() == "pending" }
        var isFailed: Bool { ["failed", "error"].contains(status.lowercased()) }
    }

    /// A batch job as these rules read it.
    struct JobFacts: Equatable, Sendable {
        let id: String
        let name: String
        let status: String

        var isFailed: Bool { ["failed", "error"].contains(status.lowercased()) }
    }

    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case signIn, sessionFailed, sessionExpiring, sessionStuck, jobFailed, compute, storageFull
        }
        let kind: Kind
        /// The session or job it is about, when it is about one.
        let subjectID: String?
        let title: String
        let detail: String?

        var id: String { "\(kind)-\(subjectID ?? "")" }
    }

    /// A running session ending within this needs the person.
    static let expiringWithin: TimeInterval = 3600
    /// A session still Pending after this is stuck.
    static let pendingTooLong: TimeInterval = 600
    /// Storage this full needs the person.
    static let storageFullPercent = 90.0

    /// - Parameters:
    ///   - seenFailedJobs: failed jobs the person has already looked at on
    ///     this device; they are no longer news.
    ///   - computeProblem: why the compute session cannot start, or what its
    ///     last run said, when either needs the person.
    static func items(signedIn: Bool, sessions: [SessionFacts], jobs: [JobFacts], seenFailedJobs: Set<String>,
                      computeProblem: String?, storagePercent: Double?, now: Date = Date()) -> [Item] {
        guard signedIn else {
            return [Item(kind: .signIn, subjectID: nil, title: String(localized: "Sign in to see your sessions and jobs"),
                         detail: nil)]
        }
        var items: [Item] = []
        for session in sessions where session.isFailed {
            items.append(Item(kind: .sessionFailed, subjectID: session.id,
                              title: String(localized: "\(session.name) failed"),
                              detail: String(localized: "Its events say why.")))
        }
        let expiring = sessions
            .compactMap { session -> (SessionFacts, Date)? in
                guard session.isRunning, let end = session.expires,
                      end > now, end.timeIntervalSince(now) <= expiringWithin else { return nil }
                return (session, end)
            }
            .sorted { $0.1 < $1.1 }
        for (session, end) in expiring {
            let left = SessionTimes.remaining(until: end, now: now) ?? ""
            items.append(Item(kind: .sessionExpiring, subjectID: session.id,
                              title: String(localized: "\(session.name) expires in \(left)"),
                              detail: String(localized: "Renew it, or save your work.")))
        }
        for session in sessions where session.isPending {
            guard let started = session.started, now.timeIntervalSince(started) > pendingTooLong else { continue }
            items.append(Item(kind: .sessionStuck, subjectID: session.id,
                              title: String(localized: "\(session.name) is still pending"),
                              detail: String(localized: "Its events say what it waits for.")))
        }
        for job in jobs where job.isFailed && !seenFailedJobs.contains(job.id) {
            items.append(Item(kind: .jobFailed, subjectID: job.id,
                              title: String(localized: "Batch job \(job.name) failed"),
                              detail: String(localized: "Its logs say why.")))
        }
        if let computeProblem, !computeProblem.isEmpty {
            items.append(Item(kind: .compute, subjectID: nil, title: String(localized: "Remote Compute needs you"),
                              detail: computeProblem))
        }
        if let storagePercent, storagePercent >= storageFullPercent {
            let percent = (storagePercent / 100).formatted(.percent.precision(.fractionLength(0)))
            items.append(Item(kind: .storageFull, subjectID: nil,
                              title: String(localized: "Your storage is \(percent) full"),
                              detail: String(localized: "Free some space before your jobs need it.")))
        }
        return items
    }
}
