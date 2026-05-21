// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Result envelope passed from the wireup layer (which holds the
/// authenticated `VOSpaceBrowserService`) to the tool. Carries the
/// bytes plus the server's `Content-Range`-reported total when
/// available — the tool uses the total to set `truncated` precisely.
struct ReadVOSpaceFetchResult: Sendable {
    let data: Data
    let totalBytes: Int?
}

/// Read a bounded slice of a VOSpace file into the tool result
/// envelope — the agent-visible counterpart to `download_from_vospace`
/// (which writes to the user's local Downloads folder, invisible to
/// the agent). Closes the 2026-05-15 QA finding that three of eight
/// Skaha jobs in a real workflow existed solely to `cat` file
/// contents back through stdout because the agent couldn't see what
/// it just wrote.
struct ReadVOSpaceFileTool: JSONReadTool {

    // VOSpace reads are typically <1s for bounded slices. 30s
    // catches the same transport-stall failure mode the
    // 2026-05-15 QA report flagged for the other VOSpace tools.
    var toolTimeoutSeconds: TimeInterval { 30 }

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
        /// Coarse content-type guess derived from the file extension.
        /// Used by the encoding decision below; the agent can also
        /// use it as a hint for downstream parsing.
        let contentType: String
        /// Either `"utf8"` or `"base64"`. Text-like content types
        /// return UTF-8 when the bytes round-trip cleanly; everything
        /// else rides base64 unconditionally.
        let encoding: String
        /// Bytes actually returned in `content` (after decoding from
        /// the wire format). For binary content this equals the
        /// pre-base64 byte count, not the base64 string length.
        let returnedBytes: Int
        /// Full file size on the server when reported via
        /// `Content-Range`; `nil` when the server didn't honour the
        /// `Range:` header or omitted the total. Use this to decide
        /// whether `truncated` reflects a partial read.
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
        description: "Read a bounded slice of a VOSpace file into the tool result — the agent-visible counterpart to `download_from_vospace` (which only writes to the user's Mac and is invisible to you). The 2026-05-15 QA report named this as a recurring pain point: three of eight Skaha jobs in a real workflow existed only to `cat` files back through stdout because the agent couldn't see what it had just written. This tool replaces that pattern with a single round-trip. `path` is the VOSpace path inside the user's home (no leading slash; `compact-groups/v1/results.fits` not `/home/me/...`). `offset` defaults to 0 and `maxBytes` defaults to 262144 (256 KB); hard cap is 1048576 (1 MB) per call — beyond that, split into multiple calls or use `download_from_vospace` to land the file on disk for the user. The response includes `totalBytes` (when the server reports it via Content-Range) and `truncated` (true when more data exists past the returned slice). `encoding` is `\"utf8\"` for textual files whose bytes round-trip cleanly (extensions: .txt, .csv, .tsv, .json, .xml, .yaml, .yml, .py, .sh, .md, .log) and `\"base64\"` for everything else (FITS, .gz, .png, .jpg) — base64 always when in doubt.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path":     { "type": "string", "minLength": 1, "description": "VOSpace path inside the user's home (no leading slash)." },
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
        } catch {
            let message = "\(error)"
            if message.lowercased().contains("auth") {
                throw ToolFailureReason.authRequired
            }
            throw ToolFailureReason.backendError(message)
        }

        let contentType = Self.inferContentType(path: args.path)
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

    /// File extensions that are reliably textual. The decision to
    /// return UTF-8 vs base64 also requires the bytes to round-trip
    /// as valid UTF-8 — having the extension here just opts the
    /// file into the *attempt*.
    static let textualExtensions: Set<String> = [
        "txt", "csv", "tsv", "json", "xml", "yaml", "yml",
        "py", "sh", "md", "log", "ini", "conf", "toml",
    ]

    /// Map file extension to a coarse content-type. Doesn't peek at
    /// the bytes — the encoding decision (`encodeContent`) does.
    static func inferContentType(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "log":            return "text/plain"
        case "csv":                   return "text/csv"
        case "tsv":                   return "text/tab-separated-values"
        case "json":                  return "application/json"
        case "xml":                   return "application/xml"
        case "py":                    return "text/x-python"
        case "sh":                    return "application/x-sh"
        case "md":                    return "text/markdown"
        case "yaml", "yml":           return "application/yaml"
        case "ini", "conf", "toml":   return "text/plain"
        case "fits":                  return "application/fits"
        case "gz":                    return "application/gzip"
        case "zip":                   return "application/zip"
        case "png":                   return "image/png"
        case "jpg", "jpeg":           return "image/jpeg"
        default:                      return "application/octet-stream"
        }
    }

    /// Decide UTF-8 vs base64. Textual extensions get a UTF-8 try
    /// first; if the bytes don't round-trip as valid UTF-8 we fall
    /// back to base64 (so a `.csv` with embedded null bytes or
    /// latin-1 garbage doesn't surface as nonsense). Everything
    /// else rides base64 directly.
    static func encodeContent(_ data: Data, contentType: String) -> (encoding: String, content: String) {
        let ext = contentType.split(separator: "/").last.map(String.init) ?? ""
        // Map content-type's subtype back to extension list when
        // possible; otherwise rely on the prefix.
        let looksTextual = contentType.hasPrefix("text/")
            || contentType == "application/json"
            || contentType == "application/xml"
            || contentType == "application/yaml"
            || contentType == "application/x-sh"
            || ext == "x-python"
        if looksTextual, let s = String(data: data, encoding: .utf8) {
            return ("utf8", s)
        }
        return ("base64", data.base64EncodedString())
    }
}
