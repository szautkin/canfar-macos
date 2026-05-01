// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Parses the JSON output of `ProbeScript` into an `ImageManifest`.
///
/// The probe writes well-formed JSON via Python; this parser is a thin
/// wrapper around `JSONDecoder` that handles two real-world wrinkles:
///   1. A schema mismatch (parser sees a manifest written by a probe
///      version newer than it understands) → returns
///      `.unknownSchema(version)` so the cache layer can ignore it.
///   2. Truncated / unreadable JSON (network drop fetching from
///      VOSpace, partial write somehow visible) →
///      `.malformed(detail)`.
///
/// Empty manifests (image had no dpkg/rpm/apk/pip/conda) are SUCCESS,
/// not failure; the parser returns the parsed manifest with empty
/// arrays and a `probeNotes` field. The cache stores the success and
/// the UI shows "no packages found" rather than "discovery failed".
enum ManifestParser {

    enum ParseError: Error, Equatable {
        case empty
        case malformed(String)
        /// The manifest's `schemaVersion` is greater than what this
        /// build of Verbinal can parse safely. Caller should treat
        /// this image as not-yet-discovered for now.
        case unknownSchema(Int)
    }

    /// Maximum schemaVersion this build understands. Bumped together
    /// with `ProbeScript.schemaVersion` whenever the probe's JSON
    /// contract changes incompatibly.
    static let maxSupportedSchemaVersion: Int = 1

    /// Parse raw probe output (UTF-8 JSON bytes) into a manifest.
    /// Throws `ParseError` on failure; never crashes on malformed
    /// input.
    static func parse(_ data: Data) throws -> ImageManifest {
        guard !data.isEmpty else {
            throw ParseError.empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let manifest = try decoder.decode(ImageManifest.self, from: data)
            guard manifest.schemaVersion <= Self.maxSupportedSchemaVersion else {
                throw ParseError.unknownSchema(manifest.schemaVersion)
            }
            return manifest
        } catch let pe as ParseError {
            throw pe
        } catch let DecodingError.dataCorrupted(ctx) {
            throw ParseError.malformed("dataCorrupted: \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, _) {
            throw ParseError.malformed("missing required key: \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw ParseError.malformed("typeMismatch at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw ParseError.malformed("valueNotFound at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
        } catch {
            throw ParseError.malformed("\(error)")
        }
    }

    /// Convenience: parse from a UTF-8 string.
    static func parse(_ string: String) throws -> ImageManifest {
        try parse(Data(string.utf8))
    }
}
