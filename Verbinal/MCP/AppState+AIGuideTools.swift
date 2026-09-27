// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// AI Guide: the resolver that re-tunes tool descriptions for a live agent,
/// the screen's tool inventory, and its write appliers.
extension AppState {
    /// Build the MCP guide resolver from the live `aiGuideService`. The closures
    /// weak-capture `self` and hop to the main actor to read `@Observable`
    /// state, so a user editing a description or adding a guide re-tunes a live
    /// agent session on its next `tools/list` (same idiom as the auto-apply
    /// hook). macOS-only — this file isn't part of the iOS target.
    func makeAIGuideResolver() -> AIGuideResolver {
        // Guide tools take no arguments: one shared empty-object schema.
        let emptySchema = AIToolDefinition.withStaticSchema(
            name: "_guide_schema", description: "_",
            schema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ).inputSchema

        return AIGuideResolver(
            adjustments: { [weak self] in
                guard let self else { return .none }
                let snapshot = await MainActor.run { self.aiGuideService.snapshot() }
                let guideTools = snapshot.guides.map { guide in
                    AIToolDefinition(name: guide.name, description: guide.description, inputSchema: emptySchema)
                }
                return AIGuideResolver.Adjustments(
                    descriptionOverrides: snapshot.overrides,
                    guideTools: guideTools
                )
            },
            guideBody: { [weak self] name in
                guard let self else { return nil }
                return await MainActor.run { self.aiGuideService.snapshot().guideBody(forName: name) }
            }
        )
    }

    /// Project the live registered tools into AI Guide inputs (name + built-in
    /// description + category) for the AI Guide screen. Reads the tools the
    /// router actually exposes, so the screen and the agent always agree.
    func aiGuideToolInputs() -> [AIGuideToolInput] {
        agentsService.tools.map { tool in
            AIGuideToolInput(
                name: tool.name,
                defaultDescription: tool.definition.description,
                category: AIGuideCatalog.categoryID(forTool: tool.name)
            )
        }
    }

    /// Appliers for the five AI Guide mutations. One shared applier shape;
    /// the closures do the MainActor `aiGuideService` calls plus the
    /// built-in-name shadow check for guide names.
    func makeAIGuideAppliers(activity: AgentActivityStore) -> [any ProposalApplier] {
        // Guide (or override target) names are checked against the LIVE
        // registered tool table at apply time.
        let builtinNames: @MainActor () -> Set<String> = { [weak self] in
            guard let self else { return [] }
            return Set(self.aiGuideToolInputs().map(\.name))
        }
        return [
            AIGuideMutationApplier(kind: "set_tool_description", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(SetToolDescriptionTool.Payload.self, from: proposal.payload)
                try await MainActor.run {
                    guard builtinNames().contains(p.toolName) else {
                        throw ProposalApplyError.backendError("no tool named '\(p.toolName)'")
                    }
                    try self.aiGuideService.setOverride(toolName: p.toolName, description: p.description)
                }
            }, activity: activity),
            AIGuideMutationApplier(kind: "clear_tool_description", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(ClearToolDescriptionTool.Payload.self, from: proposal.payload)
                await MainActor.run { self.aiGuideService.clearOverride(toolName: p.toolName) }
            }, activity: activity),
            AIGuideMutationApplier(kind: "add_guide_tool", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(AddGuideToolTool.Payload.self, from: proposal.payload)
                try await MainActor.run {
                    guard !builtinNames().contains(p.name) else {
                        throw ProposalApplyError.backendError("'\(p.name)' would shadow a built-in tool")
                    }
                    _ = try self.aiGuideService.addGuide(
                        name: p.name, description: p.description, body: p.body)
                }
            }, activity: activity),
            AIGuideMutationApplier(kind: "update_guide_tool", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(UpdateGuideToolTool.Payload.self, from: proposal.payload)
                guard let id = UUID(uuidString: p.id) else {
                    throw ProposalApplyError.backendError("invalid id")
                }
                try await MainActor.run {
                    guard !builtinNames().contains(p.name) else {
                        throw ProposalApplyError.backendError("'\(p.name)' would shadow a built-in tool")
                    }
                    try self.aiGuideService.updateGuide(
                        id: id, name: p.name, description: p.description, body: p.body)
                }
            }, activity: activity),
            AIGuideMutationApplier(kind: "delete_guide_tool", mutate: { [weak self] proposal in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let p = try JSONDecoder().decode(DeleteGuideToolTool.Payload.self, from: proposal.payload)
                guard let id = UUID(uuidString: p.id) else {
                    throw ProposalApplyError.backendError("invalid id")
                }
                await MainActor.run { self.aiGuideService.deleteGuide(id: id) }
            }, activity: activity),
        ]
    }

    func makeListGuideToolsTool() -> ListGuideToolsTool {
        ListGuideToolsTool(snapshot: { [weak self] in
            guard let self else { return [] }
            return await MainActor.run {
                self.aiGuideService.guides.map {
                    ListGuideToolsTool.Output.Entry(
                        id: $0.id.uuidString, name: $0.name,
                        description: $0.description,
                        hasBody: !($0.body ?? "").isEmpty)
                }
            }
        })
    }
}
