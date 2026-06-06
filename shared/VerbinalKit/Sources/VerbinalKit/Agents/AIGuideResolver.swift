// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Host-injected hook that lets the app re-tune the MCP manifest at request time
/// **without touching the fixed router table**. The router stays the single,
/// auditable composition point; the AI Guide layers user intent on top of it:
///
///  * description overrides — substitute a user-authored description for a
///    built-in tool's, so `tools/list` advertises the re-tuned wording;
///  * guide tools — extra read-only "instruction tools" the user authored. They
///    appear in `tools/list` and, when CALLED, return stored text (there is no
///    execution — a generic handler in the bridge returns ``guideBody``).
///
/// Mirrors the ``AutoApplyHook`` idiom: a `Sendable` bag of `@Sendable async`
/// closures the bridge consults. The host implements them by hopping to the main
/// actor to read live `@Observable` state, so a user editing a description or
/// adding a guide re-tunes a live agent session on its next `tools/list`.
///
/// `nil` (the default) means "no AI Guide" — the bridge serves the plain router
/// manifest, exactly as before.
public struct AIGuideResolver: Sendable {

    /// The current re-tuning, fetched in a single hop per `tools/list` so the
    /// bridge doesn't cross the actor boundary once per tool.
    public struct Adjustments: Sendable {
        /// Built-in tool name → user override description.
        public let descriptionOverrides: [String: String]
        /// User guide tools to append to the manifest.
        public let guideTools: [AIToolDefinition]

        public init(descriptionOverrides: [String: String], guideTools: [AIToolDefinition]) {
            self.descriptionOverrides = descriptionOverrides
            self.guideTools = guideTools
        }

        public static let none = Adjustments(descriptionOverrides: [:], guideTools: [])
    }

    /// Snapshot the live overrides + guide tools (one main-actor hop).
    public let adjustments: @Sendable () async -> Adjustments

    /// The text a guide-tool call returns, or `nil` if `name` is not a guide
    /// (in which case the bridge falls through to the router as usual).
    public let guideBody: @Sendable (_ name: String) async -> String?

    public init(
        adjustments: @escaping @Sendable () async -> Adjustments,
        guideBody: @escaping @Sendable (_ name: String) async -> String?
    ) {
        self.adjustments = adjustments
        self.guideBody = guideBody
    }
}
