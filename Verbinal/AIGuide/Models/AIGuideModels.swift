// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A user-authored "instruction tool": named, read-only guidance the AI agent
/// discovers in `tools/list` and can CALL to receive `body` (there is no
/// execution — a generic handler returns the stored text). `name` is the
/// agent-facing tool name (a sanitized slug, see ``AIGuideService.slug(_:)``).
struct AIGuideToolEntry: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    var name: String
    var description: String
    var body: String?

    /// What a call to this guide returns: the body if present, else the
    /// description (a one-liner can stand alone as its own answer).
    var callPayload: String {
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return body }
        return description
    }
}

/// One built-in tool fed to the merge. Keeps ``AIGuideService`` decoupled from
/// the router/manifest types — the UI layer projects the live manifest into
/// these before asking the service to merge in overrides.
struct AIGuideToolInput: Sendable, Equatable {
    let name: String
    let defaultDescription: String
    let category: String
}

/// A derived row for the AI Guide UI: a built-in tool's default description
/// merged with any user override. Never persisted (computed per render).
struct AIGuideTool: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let defaultDescription: String
    let effectiveDescription: String
    let isOverridden: Bool
    let category: String
}

/// Immutable, `Sendable` snapshot the MCP bridge reads to (a) substitute
/// descriptions in `tools/list` and (b) list + answer user guide tools. Built
/// on the main actor from ``AIGuideService`` state and captured by the bridge's
/// resolver closures, so it crosses the bridge actor without a hop.
struct AIGuideSnapshot: Sendable, Equatable {
    let overrides: [String: String]      // toolName -> override description
    let guides: [AIGuideToolEntry]

    static let empty = AIGuideSnapshot(overrides: [:], guides: [])

    /// Effective description for a built-in tool: override if present, else the
    /// caller's built-in default.
    func description(forTool name: String, default def: String) -> String {
        overrides[name] ?? def
    }

    /// The payload a guide-tool call returns, or `nil` if `name` isn't a guide.
    func guideBody(forName name: String) -> String? {
        guides.first(where: { $0.name == name })?.callPayload
    }
}

/// User-actionable validation failures surfaced by the edit sheets.
enum AIGuideError: LocalizedError, Equatable {
    case tooLong(field: String, limit: Int)
    case nameEmpty
    case nameTaken
    case nameCollidesWithTool

    var errorDescription: String? {
        switch self {
        case .tooLong(let field, let limit):
            return "\(field) exceeds the \(limit)-character limit."
        case .nameEmpty:
            return "Enter a name using letters, numbers, spaces, or underscores."
        case .nameTaken:
            return "You already have a guide tool with this name."
        case .nameCollidesWithTool:
            return "That name is already used by a built-in tool. Choose another."
        }
    }
}
