// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

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
        /// Still loading when the wait ran out — large, not failed.
        var stillLoading = false
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
