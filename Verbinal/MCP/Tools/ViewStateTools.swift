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
        description: "Open a downloaded observation's FITS file in the in-app viewer AND navigate the user's window to the FITS Viewer mode (so they actually see what you opened). Live-applied; no proposal. Argument is the downloaded-observation UUID returned by `list_downloaded_observations`, not a publisher_id.",
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

    let openFITS: @Sendable (_ id: String) async throws -> (observationID: String, localPath: String)

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        do {
            let result = try await openFITS(args.downloaded_observation_id)
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

// MARK: - open_cube

/// Open a downloaded observation as a 3D spectral cube in the (separate) Cube
/// Viewer. Mirrors `open_fits_file`, but routes to the Cube Viewer mode.
struct OpenCubeTool: AITool {
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
        name: "open_cube",
        description: "Open a downloaded observation as a 3D spectral cube in the in-app Cube Viewer AND navigate the user's window to the Cube Viewer mode. Live-applied; no proposal. Argument is the downloaded-observation UUID returned by `list_downloaded_observations`. Use this for FITS cubes (NAXIS≥3); for 2D images use `open_fits_file`.",
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

    let openCube: @Sendable (_ id: String) async throws -> (observationID: String, localPath: String)

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        do {
            let result = try await openCube(args.downloaded_observation_id)
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
        description: "Pre-position the search form on (RA, Dec) in degrees. Live-applied; visible the next time the user opens Search. Does NOT auto-navigate — chain `navigate_to(mode: \"search\")` after this if you want the user to see it immediately. Existing radius/collection filters in the form are preserved.",
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

// MARK: - choose_viewer

/// Dismiss the NAXIS≥3 "Open as…" sheet by picking 2D FITS, 3D Cube,
/// or closing it. Live-applied. The sheet is the same one the user
/// sees after dropping a cube or clicking a local/VOSpace FITS with
/// a third axis — `get_current_view.pendingViewerChoice` is set
/// while it is up.
struct ChooseViewerTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let viewer: String
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let viewer: String
        let path: String?
        let note: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "choose_viewer",
        description: "Pick 2D vs 3D for the Open as… sheet that appears when a FITS file has NAXIS≥3. Pass viewer 'fits' (2D FITS Viewer), 'cube' (3D Cube Viewer), or 'dismiss' (close the sheet without opening). Live-applied; no proposal. Call this when `get_current_view.pendingViewerChoice` is set — FITS/cube steering tools will fail until the sheet is resolved. Prefer `open_fits_file` / `open_cube` / `open_local_file(viewer:)` when you already know which viewer you want, so the sheet never appears.",
        schema: #"""
        {
          "type": "object",
          "required": ["viewer"],
          "properties": {
            "viewer": {
              "type": "string",
              "enum": ["fits", "cube", "dismiss"],
              "description": "fits = 2D FITS Viewer; cube = 3D Cube Viewer; dismiss = close the sheet."
            }
          },
          "additionalProperties": false
        }
        """#
    )

    let choose: @Sendable (_ viewer: String) async throws -> Output

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        let viewer = args.viewer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["fits", "cube", "dismiss"].contains(viewer) else {
            return .failed(.invalidArgument("viewer must be 'fits', 'cube', or 'dismiss'"))
        }
        do {
            let body = try await choose(viewer)
            let bytes = try JSONEncoder().encode(body)
            return .data(bytes)
        } catch let f as ToolFailureReason {
            return .failed(f)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
