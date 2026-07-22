// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Exposes an existing tool under a second wire name (Windows↔macOS
/// parity aliases). Generic over the inner tool so the router reads the
/// *inner* type's static `verbClass` / `agentSafe` — a write alias is
/// gated exactly like the tool it wraps, produces the same proposal
/// kind, and existing appliers apply it unchanged.
///
/// Deliberately no `any AITool`-taking variant: an existential wrapper
/// cannot forward the inner metatype's `verbClass`, so it would have to
/// hardcode one — and a destructive tool registered through it would be
/// gated as that hardcoded class, bypassing the proposal queue.
public struct AliasedToolBox<Inner: AITool>: AITool {
    public static var verbClass: VerbClass { Inner.verbClass }
    public static var agentSafe: Bool { Inner.agentSafe }

    private let inner: Inner
    public let definition: AIToolDefinition

    public init(name: String, description: String, inner: Inner) {
        self.inner = inner
        self.definition = AIToolDefinition(
            name: name,
            description: description + " (Alias of `\(inner.definition.name)` for cross-platform wire parity.)",
            inputSchema: inner.definition.inputSchema
        )
    }

    public func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        await inner.invoke(arguments: arguments, context: context)
    }
}
