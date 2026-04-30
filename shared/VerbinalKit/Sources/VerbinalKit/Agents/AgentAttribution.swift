// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Provenance stamp left on any persistent entity that originated from
/// an MCP-connected AI agent.
///
/// Carried inline on `SavedQuery`, `DownloadedObservation`,
/// `ObservationNote`, `RecentLaunch`, etc. Optional — `nil` means the
/// user authored the entity directly. The UI surfaces a small wand
/// badge whenever the field is non-nil so the user can tell at a
/// glance which entries came from an agent.
///
/// Privacy: contains only the same compact metadata the audit log
/// already stores (SHA-prefix fingerprint of the clientID, no
/// arguments, no payload bodies). The label is whatever the client
/// reported in `clientInfo.name/version` during `initialize` — that's
/// also already in the helper log, so this carries no fresh secrets.
public struct AgentAttribution: Codable, Sendable, Equatable {
    public let proposalID: UUID
    /// 6-char SHA-256 prefix of the clientID. Stable across calls
    /// from the same agent instance, opaque enough to not reveal the
    /// raw client identifier.
    public let originFingerprint: String
    /// `clientInfo.name/version` from the MCP `initialize` handshake.
    /// Cosmetic — used in tooltips ("Created by claude-ai/0.1.0").
    public let originLabel: String
    public let appliedAt: Date
    /// Same one-liner that appeared in the proposal strip preview.
    public let summary: String

    public init(
        proposalID: UUID,
        originFingerprint: String,
        originLabel: String,
        appliedAt: Date,
        summary: String
    ) {
        self.proposalID = proposalID
        self.originFingerprint = originFingerprint
        self.originLabel = originLabel
        self.appliedAt = appliedAt
        self.summary = summary
    }

    /// Build an attribution from the proposal that's about to land. The
    /// applier calls this at the moment the user clicks Apply.
    public static func from(proposal: PendingProposal) -> AgentAttribution {
        AgentAttribution(
            proposalID: proposal.id,
            originFingerprint: AuditOrigin.from(proposal.origin).fingerprintString,
            originLabel: proposal.origin.label,
            appliedAt: Date(),
            summary: proposal.summary
        )
    }
}

extension OperationOrigin {
    /// Cosmetic label — clientID for external agents, "user" for the
    /// in-app human.
    public var label: String {
        switch self {
        case .user: return "user"
        case .external(let id): return id
        }
    }
}

extension AuditOrigin {
    /// Hex fingerprint string suitable for tooltips / UI. "user" for
    /// the in-app origin, the 6-char SHA prefix for external agents.
    public var fingerprintString: String {
        switch self {
        case .user: return "user"
        case .external(let fp): return fp
        }
    }
}
