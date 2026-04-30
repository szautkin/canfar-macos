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
/// proposal stays in the queue so the user can retry / reject from
/// the strip).
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
    public let apply: @Sendable (_ proposalID: UUID) async throws -> Void

    public init(
        shouldAutoApply: @escaping @Sendable (_ verbClass: VerbClass, _ proposal: PendingProposal) async -> Bool,
        apply: @escaping @Sendable (_ proposalID: UUID) async throws -> Void
    ) {
        self.shouldAutoApply = shouldAutoApply
        self.apply = apply
    }
}

/// What the agent sees after a successful auto-apply: the same proposal
/// envelope it would have gotten from `.proposed`, plus an explicit
/// flag so the agent can branch on "applied" vs "queued for review".
public struct AutoAppliedAck: Codable, Sendable {
    public let applied: Bool
    public let proposalID: UUID
    public let kind: String
    public let summary: String

    public init(proposal: PendingProposal) {
        self.applied = true
        self.proposalID = proposal.id
        self.kind = proposal.kind
        self.summary = proposal.summary
    }
}
