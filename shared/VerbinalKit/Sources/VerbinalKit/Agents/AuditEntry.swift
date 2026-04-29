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
    public let toolName: String
    public let verbClass: VerbClass
    public let outcome: AuditOutcome
    public let durationMS: Int
    /// Hex-encoded SHA-256 prefix (8 chars) of the raw args. Lets ops
    /// spot replays without leaking content.
    public let payloadHashPrefix: String

    public init(
        requestID: UUID,
        timestamp: Date = Date(),
        origin: AuditOrigin,
        toolName: String,
        verbClass: VerbClass,
        outcome: AuditOutcome,
        durationMS: Int,
        payloadHashPrefix: String
    ) {
        self.requestID = requestID
        self.timestamp = timestamp
        self.origin = origin
        self.toolName = toolName
        self.verbClass = verbClass
        self.outcome = outcome
        self.durationMS = durationMS
        self.payloadHashPrefix = payloadHashPrefix
    }

    /// Compute the 8-char hex prefix of the SHA-256 of `data`. Returns
    /// "empty" for an empty input so audit lines don't show an unexpected
    /// constant when args are absent.
    public static func payloadHashPrefix(of data: Data) -> String {
        guard !data.isEmpty else { return "empty" }
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    /// Single-line stable rendering for log aggregation.
    public func line() -> String {
        var parts: [String] = []
        parts.append("request_id=\(requestID.uuidString)")
        parts.append("origin=\(origin.tag)")
        parts.append("tool=\(toolName)")
        parts.append("class=\(verbClass.rawValue)")
        parts.append("outcome=\(outcome.tag)")
        parts.append("ms=\(durationMS)")
        parts.append("hash=\(payloadHashPrefix)")
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
    case proposed
    case failed(tag: String)

    public var tag: String {
        switch self {
        case .ok: return "ok"
        case .proposed: return "proposed"
        case .failed(let t): return "failed(\(t))"
        }
    }
}
