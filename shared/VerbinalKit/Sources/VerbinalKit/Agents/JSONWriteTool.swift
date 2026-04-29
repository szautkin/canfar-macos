// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Convenience refinement of `AITool` for tools that produce a proposal
/// the user must accept. Concrete write tools implement
/// `plan(_:context:)`; the default `invoke` builds the `PendingProposal`
/// and enqueues it via the context's store.
///
/// Cuts the per-tool boilerplate from ~50 lines to ~15 and centralises
/// the failure envelope so audit tags stay consistent.
public protocol JSONWriteTool: AITool {
    associatedtype Args: Decodable & Sendable

    /// Static — set by the conformer to either `.semanticWrite` or
    /// `.destructive`. Drives the budget gate and audit bucket.
    static var verbClass: VerbClass { get }

    /// Build the proposal that goes onto the queue. Throw a
    /// `ToolFailureReason` to surface a typed invalid-argument failure
    /// before anything is enqueued.
    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan
}

/// What `plan` returns. The applier on the user's strip uses
/// `kind` to dispatch and decodes `payload` against its own schema.
public struct ProposalPlan: Sendable {
    public let kind: String
    public let summary: String
    public let payload: Data

    public init(kind: String, summary: String, payload: Data) {
        self.kind = kind
        self.summary = summary
        self.payload = payload
    }

    /// Convenience factory: encode a `Codable` payload to JSON.
    public static func encoding<T: Encodable>(
        kind: String,
        summary: String,
        payload: T
    ) throws -> ProposalPlan {
        let data = try JSONEncoder().encode(payload)
        return ProposalPlan(kind: kind, summary: summary, payload: data)
    }
}

extension JSONWriteTool {
    public static var agentSafe: Bool { true }

    public func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }

        let plan: ProposalPlan
        do {
            plan = try await self.plan(args, context: context)
        } catch let f as ToolFailureReason {
            return .failed(f)
        } catch {
            return .failed(.backendError("\(error)"))
        }

        let proposal = PendingProposal(
            toolName: self.name,
            kind: plan.kind,
            summary: plan.summary,
            payload: plan.payload,
            origin: context.origin,
            requestID: context.requestID
        )
        let queued = await context.proposals.enqueue(proposal)
        return .proposed(queued)
    }
}
