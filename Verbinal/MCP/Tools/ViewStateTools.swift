// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// View-state tools — live-applied, no proposal. Verb class is
/// `.viewState`, so the router doesn't budget-gate them. These are
/// "do something on the user's UI" rather than "change persistent
/// state"; the user sees the effect immediately and can undo by
/// navigating.

// MARK: - open_fits_file

/// Open a downloaded observation's FITS file in the viewer. Resolves
/// the security-scoped bookmark before publishing the URL so the
/// sandboxed app actually has read access at the moment the viewer
/// loads.
struct OpenFITSFileTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let downloaded_observation_id: String
    }

    struct Output: Encodable, Sendable {
        let opened: Bool
        let observationID: String
        let localPath: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "open_fits_file",
        description: "Open a downloaded observation's FITS file in the in-app viewer. Live-applied (no proposal); the viewer tab opens immediately.",
        schema: #"""
        {
          "type": "object",
          "required": ["downloaded_observation_id"],
          "properties": {
            "downloaded_observation_id": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    let openFITS: @Sendable (_ id: UUID) async throws -> (observationID: String, localPath: String)

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        guard let uuid = UUID(uuidString: args.downloaded_observation_id) else {
            return .failed(.invalidArgument("downloaded_observation_id is not a UUID"))
        }
        do {
            let result = try await openFITS(uuid)
            let body = Output(opened: true, observationID: result.observationID, localPath: result.localPath)
            let bytes = try JSONEncoder().encode(body)
            return .data(bytes)
        } catch let f as ToolFailureReason {
            return .failed(f)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - set_search_focus

/// Pre-position the search form on a sky coordinate. The next time the
/// user navigates to Search, the form's RA/Dec inputs are pre-filled.
/// Live-applied.
struct SetSearchFocusTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let raDeg: Double
        let decDeg: Double
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let raDeg: Double
        let decDeg: Double
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_search_focus",
        description: "Pre-position the search form on (RA, Dec) in degrees. Live-applied; visible the next time the user opens Search.",
        schema: #"""
        {
          "type": "object",
          "required": ["raDeg", "decDeg"],
          "properties": {
            "raDeg":  { "type": "number", "minimum": 0,    "exclusiveMaximum": 360 },
            "decDeg": { "type": "number", "minimum": -90,  "maximum": 90 }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (_ ra: Double, _ dec: Double) async -> Void

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        await apply(args.raDeg, args.decDeg)
        do {
            let body = Output(applied: true, raDeg: args.raDeg, decDeg: args.decDeg)
            let bytes = try JSONEncoder().encode(body)
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
