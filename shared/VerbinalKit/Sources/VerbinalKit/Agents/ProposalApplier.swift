// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Applies a pending proposal when the user clicks Apply in the strip.
///
/// One applier per `kind` discriminator. The framework keeps the
/// proposal queue generic; concrete appliers in the app translate
/// `payload` bytes into domain mutations.
///
/// Why a separate protocol from the tool that *created* the proposal:
/// tools and appliers are owned by different actors. The tool creates
/// the proposal during an MCP turn (external origin); the applier runs
/// later, on the @MainActor, when the user clicks the strip. Decoupling
/// avoids reach-back from the bridge actor into UI state.
public protocol ProposalApplier: Sendable {
    /// Identifier matched against `PendingProposal.kind`.
    var kind: String { get }

    /// Apply the proposal. Throws on backend failure (the strip surfaces
    /// the error and leaves the proposal in the queue so the user can
    /// retry or reject).
    func apply(_ proposal: PendingProposal) async throws
}

/// Registry of appliers, keyed by `kind`. Held by AgentsService so the
/// strip UI can dispatch without reaching into AppState directly.
public actor ProposalApplierRegistry {
    private var byKind: [String: any ProposalApplier] = [:]

    public init() {}

    public func register(_ applier: any ProposalApplier) {
        byKind[applier.kind] = applier
    }

    public func register(_ appliers: [any ProposalApplier]) {
        for a in appliers { register(a) }
    }

    public func applier(for kind: String) -> (any ProposalApplier)? {
        byKind[kind]
    }

    public func registeredKinds() -> [String] {
        Array(byKind.keys).sorted()
    }
}

public enum ProposalApplyError: Error, Equatable {
    /// No applier registered for this proposal's `kind`. Likely a
    /// programmer-induced state — the tool produced a kind the host
    /// doesn't know how to apply.
    case noApplierForKind(String)
    /// Applier ran but reported a typed failure.
    case backendError(String)
}
