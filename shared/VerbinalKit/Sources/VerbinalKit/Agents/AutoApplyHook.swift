// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Lets the host opt write proposals into auto-apply at dispatch time —
/// i.e. the agent's tool call returns a *result*, not a "queued for
/// review" placeholder, because the host already decided this client
/// is allowed to mutate state without a strip click.
///
/// The host installs the hook on `AIToolRouter` at construction. The
/// router consults `shouldAutoApply` whenever a write tool returns
/// `.proposed`. On `true`, it calls `apply(proposalID:)` and converts
/// the outcome to `.data` (success) or `.failed` (apply threw — the
/// router withdraws the optimistic proposal so a deterministically
/// failing write can't linger in the queue only to fail again).
///
/// Why not bake the policy into the router: trust state lives in the
/// app layer (per-client preferences, persisted toggles, UI revoke
/// flow). Keeping the router policy-free keeps tests trivial.
public struct AutoApplyHook: Sendable {
    /// Decide whether a just-enqueued proposal should auto-apply. The
    /// router passes the verb class (so the hook can gate destructive
    /// separately) and the proposal (so it can inspect kind / origin).
    public let shouldAutoApply: @Sendable (_ verbClass: VerbClass, _ proposal: PendingProposal) async -> Bool

    /// Run the apply. Throws on backend failure — the router withdraws
    /// the optimistic auto-apply and surfaces the error to the agent.
    /// Returns optional extra JSON merged into `AutoAppliedAck` (new
    /// entity `id`, bulk `succeeded`/`failed`, …). `nil` is the common
    /// "applied, no extra fields" case.
    public let apply: @Sendable (_ proposalID: UUID) async throws -> Data?

    public init(
        shouldAutoApply: @escaping @Sendable (_ verbClass: VerbClass, _ proposal: PendingProposal) async -> Bool,
        apply: @escaping @Sendable (_ proposalID: UUID) async throws -> Data?
    ) {
        self.shouldAutoApply = shouldAutoApply
        self.apply = apply
    }
}

/// What the agent sees after a successful auto-apply: the same proposal
/// envelope it would have gotten from `.proposed`, plus an explicit
/// flag so the agent can branch on "applied" vs "queued for review".
/// Optional `id` / bulk envelopes let write tools return the entity
/// they just created so agents can chain without re-listing.
public struct AutoAppliedAck: Codable, Sendable {
    public let applied: Bool
    public let proposalID: UUID
    public let kind: String
    public let summary: String
    /// Domain entity id when the write created one (saved query, download).
    public let id: String?
    /// Partial-success envelope for bulk writes. Absent on single-item kinds.
    public let succeeded: [String]?
    public let failed: [FailedItem]?
    /// Optional agent-facing guidance (e.g. poll a read tool because
    /// the write continues app-side after this ack).
    public let note: String?
    /// The file the write made on this Mac — a figure export's (QA N8).
    public let file: String?

    public struct FailedItem: Codable, Sendable, Equatable {
        public let id: String
        public let error: String
        public init(id: String, error: String) {
            self.id = id
            self.error = error
        }
    }

    public init(proposal: PendingProposal, extraJSON: Data? = nil) {
        self.applied = true
        self.proposalID = proposal.id
        self.kind = proposal.kind
        self.summary = proposal.summary
        let extra = extraJSON.flatMap { try? JSONDecoder().decode(Extra.self, from: $0) }
        let payloadID = Self.stringField("id", in: proposal.payload)
        self.id = extra?.id ?? payloadID
        self.succeeded = extra?.succeeded
        self.failed = extra?.failed
        self.note = extra?.note
        self.file = extra?.file
    }

    /// Encode extra ack fields from an applier. Keep this the single
    /// shape `ResultReportingApplier` returns so the router stays
    /// schema-free.
    public struct Extra: Codable, Sendable {
        public var id: String?
        public var succeeded: [String]?
        public var failed: [FailedItem]?
        public var note: String?
        public var file: String?
        public init(id: String? = nil, succeeded: [String]? = nil, failed: [FailedItem]? = nil, note: String? = nil,
                    file: String? = nil) {
            self.id = id
            self.succeeded = succeeded
            self.failed = failed
            self.note = note
            self.file = file
        }
    }

    private static func stringField(_ key: String, in data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj[key] as? String
    }

    enum CodingKeys: String, CodingKey {
        case applied, proposalID, kind, summary, id, succeeded, failed, note, file
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(applied, forKey: .applied)
        try c.encode(proposalID, forKey: .proposalID)
        try c.encode(kind, forKey: .kind)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(succeeded, forKey: .succeeded)
        try c.encodeIfPresent(failed, forKey: .failed)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(file, forKey: .file)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applied = try c.decode(Bool.self, forKey: .applied)
        proposalID = try c.decode(UUID.self, forKey: .proposalID)
        kind = try c.decode(String.self, forKey: .kind)
        summary = try c.decode(String.self, forKey: .summary)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        succeeded = try c.decodeIfPresent([String].self, forKey: .succeeded)
        failed = try c.decodeIfPresent([FailedItem].self, forKey: .failed)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        file = try c.decodeIfPresent(String.self, forKey: .file)
    }
}

/// The answer to an auto-applied write still running at the call's
/// deadline: it carries on, and `get_job_status` with `jobId` (the
/// proposal's id) says how it ends — it is not refused, and must not be
/// asked for again.
public struct StillApplyingAck: Codable, Sendable {
    public let applied: Bool
    public let applying: Bool
    public let jobId: UUID
    public let proposalID: UUID
    public let kind: String
    public let summary: String
    public let note: String

    public init(proposal: PendingProposal) {
        applied = false
        applying = true
        jobId = proposal.id
        proposalID = proposal.id
        kind = proposal.kind
        summary = proposal.summary
        note = "Still applying — it carries on in Verbinal. Follow it with get_job_status(jobId); do not ask for it again."
    }
}
