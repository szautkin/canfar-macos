// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// The tool list as an agent sees it — `tools/list`, and every tool that
/// describes the tool surface (`list_apps`, `search_tools`, `man`) — built
/// in one place so the map and the territory cannot differ.
public enum PublishedManifest {

    /// The router's agent-callable tools, with the user's AI Guide
    /// descriptions in place of the built-in ones, the user's guide tools
    /// appended, and each proposing tool's description ending with the
    /// app's apply rule — after any override, so a user's wording cannot
    /// drop it.
    /// `rule` gives a proposing tool's closing sentence — the host's, by its
    /// kind of change and the person's setting (plan 30 A); nil keeps the
    /// verb class's.
    public static func tools(router: AIToolRouter, aiGuide: AIGuideResolver?,
                             rule: (@Sendable (_ tool: String, _ verbClass: VerbClass) async -> String?)? = nil)
        async -> [ToolDefinitionWire] {
        let adjustments = await aiGuide?.adjustments() ?? .none
        var tools: [ToolDefinitionWire] = []
        for definition in await router.externalManifestList() {
            let description = adjustments.descriptionOverrides[definition.name] ?? definition.description
            var ruled = description
            if let verbClass = await router.verbClass(of: definition.name) {
                if let rule, let sentence = await rule(definition.name, verbClass) {
                    ruled = description + " " + sentence
                } else {
                    ruled = AutoApplyPolicy.describe(description, verbClass: verbClass)
                }
            }
            let schema = await router.verbClass(of: definition.name)
                .map { Cause.publishing(definition.inputSchema, for: $0) } ?? definition.inputSchema
            tools.append(ToolDefinitionWire(name: definition.name, description: ruled, inputSchema: schema))
        }
        tools.append(contentsOf: adjustments.guideTools.map(\.wire))
        return tools
    }
}
