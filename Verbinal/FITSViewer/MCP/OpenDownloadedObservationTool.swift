// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - open_fits_file / open_cube

/// Open a downloaded observation's file in a viewer and bring that viewer
/// up. `open_fits_file` (2D) and `open_cube` (3D) are this one tool for the
/// two viewers. Resolves the security-scoped bookmark first so the
/// sandboxed app can read the file when the viewer loads it.
struct OpenDownloadedObservationTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let downloaded_observation_id: String
    }

    /// What the open came to.
    struct Opened: Sendable {
        let observationID: String
        let localPath: String
        /// Still loading when the wait ran out — large, not failed.
        let stillLoading: Bool
        let note: String?
    }

    struct Output: Encodable, Sendable {
        let opened: Bool
        let stillLoading: Bool
        let observationID: String
        let localPath: String
        let note: String?
    }

    let definition: AIToolDefinition
    let open: @Sendable (_ id: String) async throws -> Opened

    static func fits(open: @escaping @Sendable (_ id: String) async throws -> Opened) -> Self {
        Self(definition: definition(
            name: "open_fits_file",
            description: "Open a downloaded observation's FITS file in the in-app viewer AND navigate the user's window to the FITS Viewer mode (so they actually see what you opened). Answers once the image is on screen; a very large file still loading after ~40 s answers `stillLoading: true` instead — it lands on its own, so do not open it again (that only switches to its tab). Opening a file that is already open switches to its tab. Live-applied; no proposal. Argument is the downloaded-observation UUID returned by `list_downloaded_observations`, not a publisher_id."),
             open: open)
    }


    static func definition(name: String, description: String) -> AIToolDefinition {
        AIToolDefinition.withStaticSchema(
            name: name,
            description: description,
            schema: #"""
            {
              "type": "object",
              "required": ["downloaded_observation_id"],
              "properties": {
                "downloaded_observation_id": { "type": "string", "description": "The Research record's id (or a unique prefix), publisher id, or observation id." }
              },
              "additionalProperties": false
            }
            """#
        )
    }

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        do {
            let result = try await open(args.downloaded_observation_id)
            let body = Output(
                opened: !result.stillLoading, stillLoading: result.stillLoading,
                observationID: result.observationID, localPath: result.localPath, note: result.note)
            return .data(try JSONEncoder().encode(body))
        } catch let f as ToolFailureReason {
            return .failed(f)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
