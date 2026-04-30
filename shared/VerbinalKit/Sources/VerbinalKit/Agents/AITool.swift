// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// Public-facing tool definition. Wraps a manual JSON Schema string to
/// stay agnostic of any schema-generation library; the schema is parsed
/// at composition time so a typo crashes at startup, not on first call.
public struct AIToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    /// Convenience: construct from a literal JSON-Schema string. Crashes
    /// (precondition) at composition time if the string isn't valid JSON,
    /// so a typo can't ship.
    public static func withStaticSchema(
        name: String,
        description: String,
        schema: String
    ) -> AIToolDefinition {
        guard let bytes = schema.data(using: .utf8) else {
            preconditionFailure("AIToolDefinition[\(name)]: schema is not utf-8")
        }
        do {
            let parsed = try JSONDecoder().decode(JSONValue.self, from: bytes)
            return AIToolDefinition(
                name: name,
                description: description,
                inputSchema: parsed
            )
        } catch {
            preconditionFailure("AIToolDefinition[\(name)]: schema parse failed — \(error)")
        }
    }

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Express the definition in the wire shape expected by `tools/list`.
    public var wire: ToolDefinitionWire {
        ToolDefinitionWire(name: name, description: description, inputSchema: inputSchema)
    }
}

/// One tool exposed over MCP.
///
/// Implementations:
///   * Declare `verbClass` and `agentSafe` **statically** so the router
///     can classify before instantiation.
///   * Provide a `definition` describing themselves to the agent.
///   * Implement `invoke` to do the work.
///
/// Tools are passed an `AIToolContext` that injects every capability they
/// need (read handles, proposal queue, etc.). Tools must not reach into
/// app-global state directly; that breaks unit testability.
public protocol AITool: Sendable {
    /// What this tool *does* in the gate-class matrix. Static so the
    /// router doesn't instantiate the tool to read it.
    static var verbClass: VerbClass { get }

    /// Whether external agents (MCP clients) can call this tool. Tools
    /// that are user-only (e.g. `withdraw_proposal` initiated by the
    /// user UI) set this to `false` so external callers see
    /// `methodNotFound`.
    static var agentSafe: Bool { get }

    /// Manifest entry. Stable — agents cache it.
    var definition: AIToolDefinition { get }

    /// Entry point. `arguments` is the raw JSON of the `params.arguments`
    /// field (or `null`), so each tool deserialises against its own
    /// argument struct.
    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult
}

extension AITool {
    /// Convenience for the common case where each tool's name is its
    /// definition's name.
    public var name: String { definition.name }
}

/// Outcome envelope. Mirrors the three discriminants the bridge needs:
/// data to forward, a proposal to enqueue, or a typed failure.
public enum ToolResult: Sendable {
    /// Read tool returning data. Bytes are JSON; the bridge wraps them
    /// in a `text` content block.
    case data(Data)

    /// Write tool that has enqueued a proposal. The bridge tells the
    /// agent *what* was queued so it can reference the proposal id.
    case proposed(PendingProposal)

    /// Typed failure. The bridge converts to a `CallToolResult` with
    /// `isError: true` (per MCP convention).
    case failed(ToolFailureReason)
}

/// Typed reasons a tool can fail. New cases append; existing cases keep
/// their string forms stable so audit logs over time stay comparable.
public enum ToolFailureReason: Sendable, Equatable, CustomStringConvertible {
    case invalidArgument(String)
    /// Generic "the thing you asked about isn't here". Prefer the more
    /// specific cases below when the failure mode is known —
    /// `unknownTarget` stays for callers that legitimately don't know
    /// which sub-mode applies.
    case unknownTarget(String)
    /// Name resolver couldn't translate the target string to coords
    /// (e.g., a typo, or an object SIMBAD/NED don't index).
    /// Distinct from `unknownTarget` so the agent can tell whether to
    /// fix the spelling vs. fall back to RA/Dec input. (Platform
    /// review F-8.)
    case targetNotResolved(String)
    /// The publisher_id supplied uses a scheme or shape we don't
    /// support (e.g., a non-`ivo://` URI). Hint should explain.
    case unsupportedIdScheme(String)
    /// The caller passed a Plane-form publisher_id where an
    /// Observation-form one was expected, AND we couldn't normalise
    /// it. (Most cases are now normalised automatically — this
    /// surfaces when the input is malformed even after stripping the
    /// productID tail and `/mirror` segment.)
    case planePublisherIdNotSupported(String)
    case authRequired
    case perTurnProposalCapExceeded(limit: Int)
    case backendError(String)
    case notImplemented

    public var description: String {
        switch self {
        case .invalidArgument(let msg): return "invalidArgument: \(msg)"
        case .unknownTarget(let what): return "unknownTarget: \(what)"
        case .targetNotResolved(let name):
            return "targetNotResolved: '\(name)' did not resolve via SIMBAD/NED. Try a different spelling, or pass `ra`+`dec` directly."
        case .unsupportedIdScheme(let id):
            return "unsupportedIdScheme: '\(id)' must use the ivo:// scheme."
        case .planePublisherIdNotSupported(let id):
            return "planePublisherIdNotSupported: '\(id)' looks like a Plane publisher_id; couldn't reduce to an Observation URI."
        case .authRequired: return "authRequired"
        case .perTurnProposalCapExceeded(let limit): return "perTurnProposalCapExceeded(\(limit))"
        case .backendError(let msg): return "backendError: \(msg)"
        case .notImplemented: return "notImplemented"
        }
    }

    /// Stable short tag for audit logs (no PII).
    public var auditTag: String {
        switch self {
        case .invalidArgument: return "invalidArgument"
        case .unknownTarget: return "unknownTarget"
        case .targetNotResolved: return "targetNotResolved"
        case .unsupportedIdScheme: return "unsupportedIdScheme"
        case .planePublisherIdNotSupported: return "planePublisherIdNotSupported"
        case .authRequired: return "authRequired"
        case .perTurnProposalCapExceeded: return "perTurnProposalCapExceeded"
        case .backendError: return "backendError"
        case .notImplemented: return "notImplemented"
        }
    }
}
