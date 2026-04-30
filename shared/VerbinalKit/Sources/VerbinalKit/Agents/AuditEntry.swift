// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import CryptoKit

/// One row in the agent-call audit trail. PII safety is baked in: bodies
/// are never recorded, only a SHA-256 prefix of the raw arguments. Error
/// detail is reduced to a stable tag so log volume stays bounded.
public struct AuditEntry: Sendable, Codable, Equatable {
    public let requestID: UUID
    public let timestamp: Date
    public let origin: AuditOrigin
    /// Friendly self-reported client name (e.g. `claude-ai/0.1.0`).
    /// `origin` carries the stable hex fingerprint for dedupe; this
    /// field carries the human-readable counterpart so audit surfaces
    /// can show "claude-ai/0.1.0 (915ada)" rather than just the hex.
    /// (F-4 of the 2026-04-29 platform review.)
    public let originLabel: String
    public let toolName: String
    public let verbClass: VerbClass
    public let outcome: AuditOutcome
    public let durationMS: Int
    /// Full hex-encoded SHA-256 of the raw args (64 chars). Stored at
    /// full length so audit rows can be joined against external log
    /// streams without prefix collisions; the line() rendering trims to
    /// 8 chars for human-friendly output.
    public let payloadHash: String

    public init(
        requestID: UUID,
        timestamp: Date = Date(),
        origin: AuditOrigin,
        originLabel: String = "",
        toolName: String,
        verbClass: VerbClass,
        outcome: AuditOutcome,
        durationMS: Int,
        payloadHash: String
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.origin = origin
        self.originLabel = originLabel
        self.toolName = toolName
        self.verbClass = verbClass
        self.outcome = outcome
        self.durationMS = durationMS
        self.payloadHash = payloadHash
    }

    /// Compute the full SHA-256 hex of `data`. Returns "empty" for
    /// empty input so audit lines don't show an unexpected constant
    /// when args are absent.
    public static func payloadHash(of data: Data) -> String {
        guard !data.isEmpty else { return "empty" }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Single-line stable rendering for log aggregation. Hash is
    /// trimmed to 8 chars for terminal-friendly output.
    public func line() -> String {
        var parts: [String] = []
        parts.append("request_id=\(requestID.uuidString)")
        parts.append("origin=\(origin.tag)")
        parts.append("tool=\(toolName)")
        parts.append("class=\(verbClass.rawValue)")
        parts.append("outcome=\(outcome.tag)")
        parts.append("ms=\(durationMS)")
        parts.append("hash=\(payloadHash.prefix(8))")
        return parts.joined(separator: " ")
    }
}

/// Audit-side projection of `OperationOrigin`. We don't log the raw
/// clientID (might be a chat session UUID, semi-private); we log only the
/// kind, plus a short fingerprint when needed.
public enum AuditOrigin: Codable, Sendable, Equatable {
    case user
    case external(clientFingerprint: String)

    public var tag: String {
        switch self {
        case .user: return "user"
        case .external(let fp): return "external/\(fp)"
        }
    }

    public static func from(_ origin: OperationOrigin) -> AuditOrigin {
        switch origin {
        case .user: return .user
        case .external(let id):
            // 6-char fingerprint of the clientID — enough to disambiguate
            // concurrent agents, not enough to reconstruct.
            let digest = SHA256.hash(data: Data(id.utf8))
            let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
            return .external(clientFingerprint: String(hex.prefix(6)))
        }
    }
}

/// Outcome bucketing for audit. Discriminant tag is short and stable.
public enum AuditOutcome: Codable, Sendable, Equatable {
    case ok
    case data
    /// Proposal enqueued. Carries the proposal UUID so downstream
    /// logging can join the audit row to the proposal lifecycle event
    /// emitted later when the user applies/rejects (ADR pattern from
    /// VT: `agent_audit.payload_hash` ↔ `proposals.request_id`).
    case proposed(UUID)
    case failed(tag: String)

    public var tag: String {
        switch self {
        case .ok: return "ok"
        case .data: return "data"
        case .proposed(let id): return "proposed(\(id.uuidString))"
        case .failed(let t): return "failed(\(t))"
        }
    }
}
