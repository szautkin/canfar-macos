// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What the wireup layer's authenticated read hands the tool: the
/// service's own result, so the two cannot drift.
typealias ReadVOSpaceFetchResult = VOSpaceBrowserService.FetchResult

/// Read a bounded slice of a VOSpace file into the tool result
/// envelope — the agent-visible counterpart to `download_from_vospace`
/// (which writes to the user's local Downloads folder, invisible to
/// the agent). Closes the 2026-05-15 QA finding that three of eight
/// Skaha jobs in a real workflow existed solely to `cat` file
/// contents back through stdout because the agent couldn't see what
/// it just wrote.
struct ReadVOSpaceFileTool: JSONReadTool {


    struct Args: Decodable, Sendable {
        let path: String
        var offset: Int?
        var maxBytes: Int?
    }

    struct Output: Encodable, Sendable {
        /// Echo of the requested path so the agent can correlate
        /// the response with its call when multiple reads are in
        /// flight.
        let path: String
        /// The file's media type, by the rule a listing uses too
        /// (`VOSpaceContentType`): its extension's, else the server's.
        /// Decides the encoding below.
        let contentType: String
        /// Either `"utf8"` or `"base64"`. Text-like content types
        /// return UTF-8 when the bytes round-trip cleanly; everything
        /// else rides base64 unconditionally.
        let encoding: String
        /// Bytes actually returned in `content` (after decoding from
        /// the wire format). For binary content this equals the
        /// pre-base64 byte count, not the base64 string length.
        let returnedBytes: Int
        /// The whole file's size — from `Content-Range`, or the body's
        /// length when the server sent the whole file; `nil` when the
        /// server said neither.
        let totalBytes: Int?
        /// `true` when more data exists past the returned slice. If
        /// `totalBytes` is known, this is exact; if not, we
        /// conservatively flag `true` whenever the returned count
        /// equals `maxBytes` (so the caller doesn't assume a clean
        /// end-of-file).
        let truncated: Bool
        /// File content. UTF-8 string when `encoding == "utf8"`,
        /// base64-encoded bytes when `encoding == "base64"`. Decode
        /// per the `encoding` field.
        let content: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "read_vospace_file",
        description: "Read a bounded slice of a VOSpace file into the tool result — the agent-visible counterpart to `download_vospace_file` (which only writes to the user's Mac and is invisible to you). The 2026-05-15 QA report named this as a recurring pain point: three of eight Skaha jobs in a real workflow existed only to `cat` files back through stdout because the agent couldn't see what it had just written. This tool replaces that pattern with a single round-trip. `path` is relative to the user's home (`compact-groups/v1/results.fits`); absolute `/home/<user>/…` is accepted and stripped. `offset` defaults to 0 and `maxBytes` defaults to 262144 (256 KB); hard cap is 1048576 (1 MB) per call — beyond that, split into multiple calls or use `download_vospace_file` to land the file on disk for the user. The response includes `totalBytes` (the whole file's size, when known) and `truncated` (true when more data exists past the returned slice); read a large file in chunks by advancing `offset` by `returnedBytes`. `contentType` follows the same rule as `list_vospace_path`: the extension's type, else the server's. `encoding` is `\"utf8\"` for textual files whose bytes round-trip cleanly (extensions: .txt, .csv, .tsv, .json, .xml, .yaml, .yml, .py, .sh, .md, .log) and `\"base64\"` for everything else (FITS, .gz, .png, .jpg) — base64 always when in doubt.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path":     { "type": "string", "minLength": 1, "description": "VOSpace path relative to the user's home; `/home/<user>/…` is accepted." },
            "offset":   { "type": "integer", "minimum": 0, "description": "Byte offset to start reading from. Default 0." },
            "maxBytes": { "type": "integer", "minimum": 1, "maximum": 1048576, "description": "Maximum bytes to return this call. Default 262144 (256 KB); hard cap 1048576 (1 MB)." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Closure that performs the authenticated bounded read. The
    /// wireup layer holds the `VOSpaceBrowserService` + username
    /// and turns this into a real network call; tests can swap it
    /// for an in-memory fixture.
    let fetch: @Sendable (_ path: String, _ offset: Int, _ maxBytes: Int) async throws -> ReadVOSpaceFetchResult

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let defaultMax = 256 * 1024
        let hardCap = 1024 * 1024
        let requestedMax = args.maxBytes ?? defaultMax
        if requestedMax < 1 {
            throw ToolFailureReason.invalidArgument("maxBytes must be ≥ 1; got \(requestedMax)")
        }
        if requestedMax > hardCap {
            throw ToolFailureReason.invalidArgument(
                "maxBytes \(requestedMax) exceeds the 1 MB per-call cap. Split into multiple calls with `offset`, or use `download_from_vospace` to land the file on disk for the user."
            )
        }
        let offset = args.offset ?? 0
        if offset < 0 {
            throw ToolFailureReason.invalidArgument("offset must be ≥ 0; got \(offset)")
        }

        let result: ReadVOSpaceFetchResult
        do {
            result = try await fetch(args.path, offset, requestedMax)
        } catch VOSpaceError.invalidPath {
            throw ToolFailureReason.invalidArgument("path must not contain '..' segments")
        } catch {
            let message = "\(error)"
            if message.lowercased().contains("auth") {
                throw ToolFailureReason.authRequired
            }
            throw ToolFailureReason.backendError(message)
        }

        let contentType = VOSpaceContentType.of(path: args.path, stated: result.statedContentType)
        let (encoding, content) = Self.encodeContent(result.data, contentType: contentType)
        let truncated: Bool
        if let total = result.totalBytes {
            truncated = (offset + result.data.count) < total
        } else {
            // Server didn't report total. Conservative heuristic:
            // when we got back exactly the cap, assume more exists.
            // Smaller payloads mean we reached EOF (or the server
            // truncated for its own reasons).
            truncated = result.data.count >= requestedMax
        }
        return Output(
            path: args.path,
            contentType: contentType,
            encoding: encoding,
            returnedBytes: result.data.count,
            totalBytes: result.totalBytes,
            truncated: truncated,
            content: content
        )
    }

    /// Decide UTF-8 vs base64. Textual content types get a UTF-8 try
    /// first; if the bytes don't round-trip as valid UTF-8 we fall
    /// back to base64 (so a `.csv` with embedded null bytes or
    /// latin-1 garbage doesn't surface as nonsense). Everything
    /// else rides base64 directly.
    static func encodeContent(_ data: Data, contentType: String) -> (encoding: String, content: String) {
        if VOSpaceContentType.isText(contentType), let s = String(data: data, encoding: .utf8) {
            return ("utf8", s)
        }
        return ("base64", data.base64EncodedString())
    }
}
