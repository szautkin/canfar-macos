// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// List Skaha container images the user is allowed to launch.
///
/// Closes the gap that caused agents to hand-type `image` strings into
/// `launch_session` and get back HTTP 400 ("unknown or private image")
/// from Skaha. The catalogue at `/skaha/v1/image` is authoritative —
/// each entry carries its full registry-qualified id and the session
/// types it supports.
///
/// Read-only; no auth required beyond the user being signed in (the
/// catalogue itself is gated by the Skaha bearer token, same as the
/// in-app launch form).
struct ListSessionImagesTool: JSONReadTool {

    struct Args: Decodable, Sendable {
        /// Optional filter — keep only images whose `types` array
        /// contains this value. One of: "notebook", "desktop",
        /// "firefly", "carta", "contributed".
        let type: String?
    }

    struct Output: Encodable, Sendable {
        let images: [Entry]
        struct Entry: Encodable, Sendable {
            /// Full registry-qualified image id, e.g.
            /// "images.canfar.net/skaha/astroml:24.07". Pass this
            /// verbatim as `launch_session.image` — the value is
            /// what Skaha expects, no trimming or rebuilding.
            let id: String
            /// Session types this image can run as. Most images
            /// support one type; multi-type entries (e.g. images
            /// that run as both `notebook` and `contributed`) are
            /// rare but legal.
            let types: [String]
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_session_images",
        description: "List Skaha container images this user is allowed to launch. Returns full registry-qualified ids — pass one verbatim as `launch_session.image`. Optional `type` filter (notebook/desktop/firefly/carta/contributed). Hand-typed image strings WILL fail with HTTP 400; always pick from this list.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "type": { "type": "string", "enum": ["notebook", "desktop", "firefly", "carta", "contributed"] }
          },
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable () async throws -> [(id: String, types: [String])]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let raw: [(id: String, types: [String])]
        do {
            raw = try await fetch()
        } catch {
            throw ToolFailureReason.backendError("Skaha image catalogue: \(error.localizedDescription)")
        }
        let filter = args.type
        let entries: [Output.Entry] = raw.compactMap { entry in
            if let filter, !entry.types.contains(filter) { return nil }
            return Output.Entry(id: entry.id, types: entry.types)
        }
        return Output(images: entries)
    }
}
