// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// A control as the pointer tools report it.
struct UITargetView: Encodable, Sendable {
    let id: String
    let label: String
    let screen: String

    init(_ t: UIPointerMatcher.Target) {
        id = t.id
        label = t.label
        screen = t.screen
    }
}

// MARK: - list_ui_targets

struct ListUITargetsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        var screen: String?
    }

    struct Output: Encodable, Sendable {
        let targets: [UITargetView]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_ui_targets",
        description: "The controls on screen right now that point_at_ui can point at — id (stable), label (what the person reads) and screen. Only what is visible is listed: navigate_to or open_settings first to bring a control up. Pass `screen` (e.g. \"search\", \"settings.agent\") to narrow it.",
        schema: #"""
        {
          "type": "object",
          "properties": { "screen": { "type": "string", "description": "Only this screen's controls, by prefix." } },
          "additionalProperties": false
        }
        """#
    )

    let targets: @Sendable () async -> [UIPointerMatcher.Target]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let prefix = args.screen?.lowercased()
        let listed = await targets()
            .filter { prefix.map($0.screen.lowercased().hasPrefix) ?? true }
            .sorted { ($0.screen, $0.id) < ($1.screen, $1.id) }
        return Output(targets: listed.map(UITargetView.init))
    }
}

// MARK: - point_at_ui

struct PointAtUITool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        let target: String
        var message: String?
        var seconds: Double?
    }

    struct Output: Encodable, Sendable {
        let pointed: Bool
        let target: UITargetView?
        /// When the name did not land on exactly one control: what there is.
        let candidates: [UITargetView]
        let message: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "point_at_ui",
        description: "Show the person where a control is: a ring round it and your short message beside it, for a few seconds — the answer to \"where is that setting?\" being the app pointing at it. Name the control by its id or its label (list_ui_targets lists what is on screen). A name matching none — or two equally — points at nothing and returns the candidates instead of guessing. It shows; it never clicks or changes anything.",
        schema: #"""
        {
          "type": "object",
          "required": ["target"],
          "properties": {
            "target": { "type": "string", "minLength": 1, "description": "A control's id or label." },
            "message": { "type": "string", "description": "A short sentence shown beside it." },
            "seconds": { "type": "number", "minimum": 2, "maximum": 60, "description": "How long the hint stays (default 8)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let point: @Sendable (Args) async -> UIPointerRegistry.Outcome

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        switch await point(args) {
        case .pointed(let target):
            return Output(pointed: true, target: UITargetView(target), candidates: [], message: nil)
        case .notFound(let candidates):
            return Output(pointed: false, target: nil, candidates: candidates.map(UITargetView.init),
                          message: candidates.isEmpty
                              ? "nothing on screen can be pointed at — navigate_to or open_settings first"
                              : "no single control is called \"\(args.target)\"; these are on screen")
        }
    }
}

// MARK: - open_settings / close_settings

enum SettingsActions {
    struct OpenArgs: Decodable, Sendable { var section: String? }
    struct NoArgs: Decodable, Sendable {}

    static func open(perform: @escaping @Sendable (OpenArgs) async -> String?) -> LiveActionTool<OpenArgs> {
        let ids = SettingsSection.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        return LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "open_settings",
                description: "Open Settings at a section, so you can show the person where something is set — then point at the control with point_at_ui (list_ui_targets lists what is there). Nothing is changed: settings are the person's to set, and some (the MCP server and auto-apply, endpoints, the compute image, sign-ins) only they should. Sections: \(SettingsSection.allCases.map(\.rawValue).joined(separator: ", ")).",
                schema: #"""
                {
                  "type": "object",
                  "properties": { "section": { "type": "string", "enum": [\#(ids)] } },
                  "additionalProperties": false
                }
                """#),
            perform: perform)
    }

    static func close(perform: @escaping @Sendable (NoArgs) async -> String?) -> LiveActionTool<NoArgs> {
        LiveActionTool(
            definition: AIToolDefinition.withStaticSchema(
                name: "close_settings",
                description: "Close the Settings window. Live-applied; no proposal.",
                schema: #"{"type":"object","properties":{},"additionalProperties":false}"#),
            perform: perform)
    }
}
