// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One row in the persisted agent activity feed.
///
/// Distinct from `AuditEntry` (which is per-call diagnostic with a
/// SHA hash) and `AgentEvent` (in-memory ring driven by proposal
/// lifecycle). This type captures the *user-meaningful* trail of what
/// the agent did, with enough context to drive a "Recent" tab in the
/// toolbar wand popover and per-row attribution lookups: applied
/// proposals, rejected/withdrawn proposals, and live-applied
/// view-state ops that wouldn't otherwise leave a persistent crumb.
public struct AgentActivityEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    /// Stable kind discriminator. Matches the proposal kind for write
    /// outcomes; for view-state ops uses prefixed strings like
    /// `viewstate:set_search_focus` so UI can distinguish.
    public let kind: String
    /// Same wording as the proposal summary or a one-liner generated
    /// by the view-state op.
    public let summary: String
    /// Same fingerprint as `AgentAttribution.originFingerprint`.
    public let originFingerprint: String
    public let originLabel: String
    /// `nil` for view-state ops (no proposal).
    public let proposalID: UUID?
    /// Final outcome — drives the icon in the activity feed:
    /// `applied` / `rejected` / `withdrawn` / `live`.
    public let outcome: Outcome

    public enum Outcome: String, Codable, Sendable, Equatable {
        /// Write proposal, user clicked Apply, applier succeeded.
        case applied
        /// Write proposal, user clicked Reject (or strip retracted on
        /// budget overflow on the agent side).
        case rejected
        /// Write proposal the agent withdrew itself.
        case withdrawn
        /// View-state op — applied immediately, no proposal flow.
        case live
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: String,
        summary: String,
        originFingerprint: String,
        originLabel: String,
        proposalID: UUID? = nil,
        outcome: Outcome
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
        self.originFingerprint = originFingerprint
        self.originLabel = originLabel
        self.proposalID = proposalID
        self.outcome = outcome
    }

    // MARK: - Factories

    /// Build an `applied` entry from the proposal that just landed.
    /// Convenience for appliers — they all need this exact shape.
    public static func applied(proposal: PendingProposal, kind: String) -> AgentActivityEntry {
        AgentActivityEntry(
            kind: kind,
            summary: proposal.summary,
            originFingerprint: AuditOrigin.from(proposal.origin).fingerprintString,
            originLabel: proposal.origin.label,
            proposalID: proposal.id,
            outcome: .applied
        )
    }

    /// Build a `rejected` entry. Called from the proposal-strip
    /// reject path so the breadcrumb survives.
    public static func rejected(proposal: PendingProposal) -> AgentActivityEntry {
        AgentActivityEntry(
            kind: proposal.kind,
            summary: proposal.summary,
            originFingerprint: AuditOrigin.from(proposal.origin).fingerprintString,
            originLabel: proposal.origin.label,
            proposalID: proposal.id,
            outcome: .rejected
        )
    }

    /// Build a `withdrawn` entry. Called when the agent retracts its
    /// own pending proposal.
    public static func withdrawn(proposal: PendingProposal) -> AgentActivityEntry {
        AgentActivityEntry(
            kind: proposal.kind,
            summary: proposal.summary,
            originFingerprint: AuditOrigin.from(proposal.origin).fingerprintString,
            originLabel: proposal.origin.label,
            proposalID: proposal.id,
            outcome: .withdrawn
        )
    }

    /// Build a `live` entry for a view-state op that doesn't flow
    /// through the proposal queue.
    public static func live(
        kind: String,
        summary: String,
        origin: OperationOrigin
    ) -> AgentActivityEntry {
        AgentActivityEntry(
            kind: "viewstate:\(kind)",
            summary: summary,
            originFingerprint: AuditOrigin.from(origin).fingerprintString,
            originLabel: origin.label,
            proposalID: nil,
            outcome: .live
        )
    }
}
