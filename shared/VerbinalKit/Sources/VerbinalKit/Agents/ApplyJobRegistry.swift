// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Applies that outlived the call that started them — a 1.6 GB download an
/// agent asked for, or one started with `start_background_apply` — and how
/// each ended, so `get_job_status` can tell the agent instead of the work
/// vanishing at the client's timeout. A job's id is its proposal's id: one
/// identifier the agent already holds.
public actor ApplyJobRegistry {

    public enum Status: String, Sendable, Codable {
        case running, succeeded, failed
    }

    public struct Job: Sendable, Equatable {
        public let id: UUID
        public let kind: String
        public let summary: String
        public let started: Date
        public var finished: Date?
        public var status: Status
        /// Why it failed.
        public var message: String?
        /// What the applier reported on success (JSON), if anything.
        public var result: Data?
    }

    /// Finished jobs are kept so an outcome can be read after the fact;
    /// bounded so a long session cannot grow it without limit.
    public static let capacity = 60

    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func start(_ proposal: PendingProposal) {
        if jobs[proposal.id] == nil { order.append(proposal.id) }
        jobs[proposal.id] = Job(id: proposal.id, kind: proposal.kind, summary: proposal.summary,
                                started: now(), finished: nil, status: .running, message: nil, result: nil)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            jobs[oldest] = nil
        }
    }

    public func succeed(_ id: UUID, result: Data?) {
        jobs[id]?.status = .succeeded
        jobs[id]?.result = result
        jobs[id]?.finished = now()
    }

    public func fail(_ id: UUID, message: String) {
        jobs[id]?.status = .failed
        jobs[id]?.message = message
        jobs[id]?.finished = now()
    }

    public func job(_ id: UUID) -> Job? { jobs[id] }
}
