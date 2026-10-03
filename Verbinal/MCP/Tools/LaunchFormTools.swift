// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What the launch form shows after an agent opened (or closed) it.
struct LaunchFormShown: Encodable, Sendable {
    let shown: Bool
    let tab: String?
    let image: String?
    /// Where the image came from: "catalogue" (the Standard tab's list) or
    /// "custom" (the Advanced tab's own image).
    let imageSource: String?
}

/// `show_launch_form` — the Portal's launch form on the person's screen,
/// at a tab, with an image; it launches nothing.
struct ShowLaunchFormTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {
        var tab: String?
        var image: String?
        var resources: String?
        var cores: Int?
        var ram: Int?
        var gpus: Int?
        var close: Bool?
    }

    static let tabs: [String: AppState.LaunchFormTab] = ["standard": .standard, "advanced": .advanced, "headless": .headless]

    let definition = AIToolDefinition.withStaticSchema(
        name: "show_launch_form",
        description: "Open the Portal's launch form — the sheet Launch Session on Active Sessions opens — so the person sees it and point_at_ui can point at its controls (portal.launch …). `tab` shows standard, advanced or headless; `image` chooses an image by its id, as the images card's \"Use this image\" does: one from the catalogue on the Standard (or Headless) tab, any other as the Advanced tab's own image. `resources` sets Flexible or Fixed, and `cores`, `ram` (GB) and `gpus` the fixed size — one given makes it Fixed — from the sizes the form offers. `close` closes it. It launches nothing — launch_session does, or the person. The person must be signed in.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "tab": { "type": "string", "enum": ["standard", "advanced", "headless"], "description": "Which tab to show." },
            "image": { "type": "string", "description": "An image id to choose, e.g. images.canfar.net/skaha/astroml:24.07." },
            "resources": { "type": "string", "enum": ["flexible", "fixed"], "description": "Flexible, or a fixed size." },
            "cores": { "type": "integer", "minimum": 1, "description": "Fixed CPU cores, one the form offers." },
            "ram": { "type": "integer", "minimum": 1, "description": "Fixed RAM in GB, one the form offers." },
            "gpus": { "type": "integer", "minimum": 0, "description": "Fixed GPUs, one the form offers." },
            "close": { "type": "boolean", "description": "Close the form instead (default false)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let show: @Sendable (Args) async throws -> LaunchFormShown

    func handle(_ args: Args, context: AIToolContext) async throws -> LaunchFormShown {
        if let tab = args.tab, Self.tabs[tab.lowercased()] == nil {
            throw ToolFailureReason.invalidArgument("tab must be standard, advanced or headless")
        }
        return try await show(args)
    }
}
