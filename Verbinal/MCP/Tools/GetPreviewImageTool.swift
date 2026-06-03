// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `get_preview_image` — fetch a CADC observation's preview image **server-side**
/// (Verbinal's host has CADC network reach + the user's auth) and return it as an
/// inline MCP image block the agent can display, plus a JSON metadata block that
/// also carries the base64 bytes.
///
/// Why server-side: the agent's sandbox blocks CADC hosts (`403 host_not_allowed`),
/// so a client-side fetch can never display the image. This tool is the
/// `read_vospace_file` pattern pointed at DataLink/CAOM-2 previews.
///
/// Resolution (verified against the IVOA DataLink 1.0 standard + CADC's CAOM-2):
/// the **band → preview** mapping comes from CAOM-2 (each plane's
/// `energy.bandpassName` + its `productType:"preview"`, `content_type image/*`
/// artifact); the preview's `access_url` 302-redirects to a signed `minoc` URL
/// (a spec-permitted "dynamic resource" access_url) which the fetch follows and
/// mints fresh per call. Proprietary/embargoed data surfaces as HTTP 401/403
/// (not a DataLink `error_message`), mapped to `authRequired`.
struct GetPreviewImageTool: AITool {
    static var verbClass: VerbClass { .read }
    static var agentSafe: Bool { true }

    /// Claude Desktop (and other MCP clients) reject a response body larger
    /// than ~1 MB. The image ships as base64 in the MCP image block (≈4/3
    /// inflation), so we cap the RAW image so its base64 — plus the small JSON
    /// metadata envelope — stays comfortably under that limit. Previews are
    /// typically 300–530 KB, so real previews pass through; a mis-resolved
    /// giant file is refused with `previewTooLarge`.
    static let mcpResponseByteLimit = 1_048_576   // 1 MB
    static let defaultMaxBytes = 680 * 1024       // ≈ 696 KB raw → ~928 KB base64

    /// A candidate preview artifact resolved from CAOM-2/DataLink.
    struct PreviewArtifact: Sendable, Equatable {
        let band: String?            // plane bandpassName (nil if the plane has none)
        let url: URL                 // access_url (follows a redirect to signed storage)
        let contentType: String?     // declared mime (e.g. image/gif)
        let contentLength: Int64?    // declared size, for the pre-fetch cap
        let filename: String
    }

    /// Errors the injected byte-fetcher can throw; the tool maps them to typed
    /// `ToolFailureReason`s so the failure modes the spec calls out never repeat.
    enum PreviewFetchError: Error, Sendable {
        case tooLarge(Int)         // Content-Length exceeded the cap (pre-body)
        case authRequired          // 401/403 — proprietary/embargoed
        case http(Int)             // other non-2xx
        case timedOut              // the fetch leg's own watchdog fired
        case transport(String)     // connection failure
    }

    /// Injected so the tool is testable without TAPClient/CAOM-2/networking
    /// (mirrors `GetDataLinksTool.fetch`). The wiring layer composes the real
    /// CAOM-2 → preview-artifact resolution and the authenticated, redirect-
    /// following byte fetch.
    let resolvePreviews: @Sendable (_ publisherID: String) async throws -> [PreviewArtifact]
    let fetchImage: @Sendable (_ url: URL, _ maxBytes: Int) async throws -> (data: Data, contentType: String?)

    var toolTimeoutSeconds: TimeInterval { 30 }

    struct Args: Decodable, Sendable {
        let publisher_id: String
        let band: String?
        let max_bytes: Int?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_preview_image",
        description: "Fetch a CADC observation's PREVIEW image server-side and return it as an inline image you can display to the user, plus a small JSON metadata block (filename, band, byteSize, sourceURL, contentType). The image itself is the inline image block — it is NOT duplicated as base64 in the JSON. Use the same publisher_id as get_data_links / get_observation_caom2. The backend fetches the bytes using the user's CADC auth (the agent sandbox blocks CADC hosts, so a client-side fetch can't display previews), follows the redirect to signed storage, and returns the raw image — never a URL. It resolves to a preview artifact (contentType image/*, productType preview), NEVER a science frame: pass `band` (e.g. G.MP9401) to pick a band for multi-band observations; omit it for the default preview. Safety: `max_bytes` (default ~680 KB, hard-capped) refuses a mis-resolved giant file and keeps the base64 response under MCP clients' ~1 MB body limit. Typed errors: previewNotFound (lists bands that DO have previews), previewTooLarge, authRequired (proprietary/embargoed), upstreamTimeout, contentTypeMismatch (the fetched bytes weren't a valid image). Bounded by a 30s watchdog.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisher_id"],
          "properties": {
            "publisher_id": { "type": "string" },
            "band": { "type": "string" },
            "max_bytes": { "type": "integer", "minimum": 1 }
          },
          "additionalProperties": false
        }
        """#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("get_preview_image: \(error)"))
        }
        let publisherID = args.publisher_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publisherID.isEmpty else {
            return .failed(.invalidArgument("publisher_id is required"))
        }
        // Clamp to the MCP-safe cap so a caller-supplied max_bytes can't push
        // the base64 response past the ~1 MB client limit.
        let maxBytes = min(max(1, args.max_bytes ?? Self.defaultMaxBytes), Self.defaultMaxBytes)

        do {
            return try await withToolTimeout(seconds: toolTimeoutSeconds, label: "get_preview_image") {
                try await self.run(publisherID: publisherID, band: args.band, maxBytes: maxBytes)
            }
        } catch let reason as ToolFailureReason {
            // Includes withToolTimeout's own deadline (backendError) and every
            // typed failure `run` throws.
            return .failed(reason)
        } catch {
            return .failed(.backendError("get_preview_image: \(error.localizedDescription)"))
        }
    }

    private func run(publisherID: String, band: String?, maxBytes: Int) async throws -> ToolResult {
        // 1. Resolve preview artifacts; keep only image/* previews — never a science frame.
        let artifacts = try await resolvePreviews(publisherID)
        let previews = artifacts.filter { Self.isImageContentType($0.contentType) || Self.hasImageExtension($0.filename) }
        guard !previews.isEmpty else {
            throw ToolFailureReason.previewNotFound("no preview images for \(publisherID)")
        }

        // 2. Pick by band, or the default (first) preview.
        let chosen: PreviewArtifact
        if let band = band?.trimmingCharacters(in: .whitespaces), !band.isEmpty {
            guard let match = previews.first(where: { $0.band?.caseInsensitiveCompare(band) == .orderedSame }) else {
                let bands = previews.compactMap(\.band)
                let list = bands.isEmpty ? "(none of the previews declare a band)" : Array(Set(bands)).sorted().joined(separator: ", ")
                throw ToolFailureReason.previewNotFound("no preview for band '\(band)'. Available preview bands: \(list)")
            }
            chosen = match
        } else {
            chosen = previews[0]
        }

        // 3. Cap by declared Content-Length before transferring the body.
        if let len = chosen.contentLength, len > maxBytes {
            throw ToolFailureReason.previewTooLarge(Int(len))
        }

        // 4. Fetch bytes server-side (follows redirect; uses CADC auth).
        let data: Data
        let fetchedType: String?
        do {
            (data, fetchedType) = try await fetchImage(chosen.url, maxBytes)
        } catch let e as PreviewFetchError {
            switch e {
            case .tooLarge(let n):                 throw ToolFailureReason.previewTooLarge(n)
            case .authRequired:                    throw ToolFailureReason.authRequired
            case .http(401), .http(403):           throw ToolFailureReason.authRequired
            case .http(let code):                  throw ToolFailureReason.backendError("HTTP \(code) fetching preview")
            case .timedOut:                        throw ToolFailureReason.upstreamTimeout("preview fetch timed out")
            case .transport(let m):                throw ToolFailureReason.backendError(m)
            }
        }

        // 5. Verify the bytes are actually an image. Known magic bytes are
        //    authoritative; for any other format we trust a declared image/*
        //    content type as long as the payload isn't a text/markup error body.
        //    Catches the "403 host_not_allowed body shipped as an image" failure.
        guard let mimeType = Self.imageMimeType(of: data, declared: fetchedType ?? chosen.contentType) else {
            let head = String(data: data.prefix(80), encoding: .utf8).map { " — head: \($0)" } ?? ""
            throw ToolFailureReason.contentTypeMismatch(
                "fetched \(data.count) bytes that are not a recognised image (declared \(fetchedType ?? chosen.contentType ?? "?"))\(head)"
            )
        }

        // 6. Safety net: the fetcher already honours maxBytes, but guard
        //    against a server that over-sends so the base64 response can never
        //    exceed the MCP client's ~1 MB body limit.
        guard data.count <= Self.defaultMaxBytes else {
            throw ToolFailureReason.previewTooLarge(data.count)
        }

        // 7. Build the inline image + a LEAN JSON metadata block. The image
        //    rides in the MCP image block (base64 over the wire); we do NOT
        //    duplicate it as base64 in the caption — that doubled the payload
        //    and blew past Claude Desktop's ~1 MB response limit.
        let meta = Metadata(
            filename: chosen.filename,
            band: chosen.band,
            byteSize: data.count,
            sourceURL: chosen.url.absoluteString,
            contentType: mimeType
        )
        let caption = (try? Self.prettyJSON(meta)) ?? "{\"byteSize\": \(data.count), \"contentType\": \"\(mimeType)\"}"
        return .image(data: data, mimeType: mimeType, caption: caption)
    }

    // MARK: - Metadata

    private struct Metadata: Encodable {
        let filename: String
        let band: String?
        let byteSize: Int
        let sourceURL: String
        let contentType: String
    }

    private static func prettyJSON(_ value: some Encodable) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try enc.encode(value), as: UTF8.self)
    }

    // MARK: - Image typing

    static func isImageContentType(_ type: String?) -> Bool {
        (type ?? "").lowercased().hasPrefix("image/")
    }

    static func hasImageExtension(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["gif", "png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "jp2"].contains(ext)
    }

    /// Resolve the image mime type for the fetched bytes. Known magic bytes
    /// (GIF/PNG/JPEG/WebP/BMP/TIFF) are authoritative; for any *other* format
    /// (e.g. JPEG-2000, FITS-rendered PNG variants) we trust a declared
    /// `image/*` content type — UNLESS the payload looks like a text/markup
    /// error body (the "403 host_not_allowed string shipped as an image"
    /// failure). Returns nil when the bytes can't be treated as an image.
    static func imageMimeType(of data: Data, declared: String? = nil) -> String? {
        let head = Array(data.prefix(16))
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }                   // "GIF8"
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.count >= 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]),                       // "RIFF"…"WEBP"
           Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if head.starts(with: [0x42, 0x4D]) { return "image/bmp" }                               // "BM"
        if head.starts(with: [0x49, 0x49, 0x2A, 0x00]) || head.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"                                                                 // II*. / MM.*
        }
        // Unknown magic — accept any declared image/* type, but never a
        // text/markup body masquerading as an image.
        if let declared = declared?.lowercased(),
           declared.hasPrefix("image/"),
           !looksLikeTextErrorBody(data) {
            return declared
        }
        return nil
    }

    /// True when a payload is almost certainly a text/HTML/JSON error body
    /// rather than image bytes: small, and printable ASCII or starting with
    /// markup. Real image bytes are binary and fail this.
    static func looksLikeTextErrorBody(_ data: Data) -> Bool {
        guard data.count < 8192 else { return false }   // a large body is plausibly an image
        if data.first == 0x3C { return true }            // '<' → HTML / XML / VOTable error
        guard let text = String(data: data, encoding: .utf8) else { return false }  // invalid UTF-8 → binary
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }   // JSON error
        // Decodes cleanly as UTF-8 text of modest size → treat as an error string.
        return true
    }
}
