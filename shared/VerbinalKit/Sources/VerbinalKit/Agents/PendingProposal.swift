// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One pending proposal in the strip queue.
///
/// The framework treats `payload` as opaque — it just stores and surfaces
/// the bytes. The application's *applier* (per-kind dispatcher) decodes
/// the payload when the user clicks Apply. This split keeps the queue
/// generic across any future tool, while letting each tool ship its own
/// argument schema.
public struct PendingProposal: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Name of the tool that produced this proposal — useful for logging
    /// and dispatching the applier.
    public let toolName: String
    /// Stable kind discriminator the applier uses to route the payload.
    /// Often equals `toolName`, but bulk tools may produce nested kinds
    /// (e.g. tool `download_observations_bulk` → kind `download_observation_batch`).
    public let kind: String
    /// Human-readable preview shown in the strip ("Download 5 observations
    /// from JWST · 2.4 GB").
    public let summary: String
    /// Opaque arguments the applier decodes. JSON bytes.
    public let payload: Data
    public let createdAt: Date
    public let origin: OperationOrigin

    public init(
        id: UUID = UUID(),
        toolName: String,
        kind: String,
        summary: String,
        payload: Data,
        createdAt: Date = Date(),
        origin: OperationOrigin
    ) {
        self.id = id
        self.toolName = toolName
        self.kind = kind
        self.summary = summary
        self.payload = payload
        self.createdAt = createdAt
        self.origin = origin
    }
}

/// Lifecycle state of a proposal as observed externally (e.g. by the
/// agent calling `get_proposal_state`).
public enum ProposalState: String, Codable, Sendable, Equatable {
    case pending
    case applied
    case rejected
    /// Agent retracted its own pending proposal (e.g. budget overflow,
    /// or a self-correction realised mid-flow).
    case withdrawn
    /// Not in the queue, no tombstone — never existed or older than the
    /// retention window.
    case unknown
}
