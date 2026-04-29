// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Fetch DataLink-discovered URLs for an observation: thumbnails, preview
/// images, and direct file URLs. The `bestDirectFile` is the agent's
/// recommended starting point for a download.
struct GetDataLinksTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let publisher_id: String
    }

    struct Output: Encodable, Sendable {
        let thumbnails: [String]
        let previews: [String]
        let files: [FileOut]
        let bestDirectFileURL: String?

        struct FileOut: Encodable, Sendable {
            let url: String
            let contentType: String
            let filename: String
            let isUncompressedFITS: Bool
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_data_links",
        description: "Fetch thumbnail / preview / direct-download URLs for a CADC observation by publisher_id.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisher_id"],
          "properties": {
            "publisher_id": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Closure shape so the tool doesn't depend on TAPClient directly,
    /// keeping unit tests simple.
    let fetch: @Sendable (_ publisherID: String) async throws -> (
        thumbnails: [URL], previews: [URL], files: [(url: URL, contentType: String, filename: String, isUncompressedFITS: Bool)]
    )

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let r = try await fetch(args.publisher_id)
        let files = r.files.map {
            Output.FileOut(
                url: $0.url.absoluteString,
                contentType: $0.contentType,
                filename: $0.filename,
                isUncompressedFITS: $0.isUncompressedFITS
            )
        }
        let best = files.first(where: { $0.isUncompressedFITS })?.url ?? files.first?.url
        return Output(
            thumbnails: r.thumbnails.map(\.absoluteString),
            previews: r.previews.map(\.absoluteString),
            files: files,
            bestDirectFileURL: best
        )
    }
}
