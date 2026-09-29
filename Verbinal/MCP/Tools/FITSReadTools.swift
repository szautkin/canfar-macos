// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - get_fits_header

/// Return all FITS header cards for the first image HDU of a downloaded
/// observation. Agents pass a downloaded_observation_id (UUID); the tool
/// resolves to the local file via the security-scoped bookmark.
struct GetFITSHeaderTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let downloaded_observation_id: String
        var hduIndex: Int?
        var keywords: [String]?
    }

    struct Output: Encodable, Sendable {
        let observationID: String
        let hduIndex: Int
        /// The header's cards with a keyword or words, before `keywords` chose.
        let totalCards: Int
        let cards: [Card]
        struct Card: Encodable, Sendable {
            let keyword: String
            let value: String
            let comment: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_fits_header",
        description: "Return FITS header cards for one HDU of a previously-downloaded observation. Argument is the `downloaded_observation_id` (UUID from `list_downloaded_observations`), NOT a `publisher_id` — the file must already be on disk. Call `download_observation` first if you don't have a local copy. Defaults to the first image HDU. `keywords` returns only the cards whose keyword starts with one of them (`[\"NAXIS\", \"CRVAL\", \"DATE-OBS\"]`); blank cards are never returned.",
        schema: #"""
        {
          "type": "object",
          "required": ["downloaded_observation_id"],
          "properties": {
            "downloaded_observation_id": { "type": "string" },
            "hduIndex": { "type": "integer", "minimum": 0 },
            "keywords": { "type": "array", "items": { "type": "string" }, "description": "Keywords or their prefixes, any case" }
          },
          "additionalProperties": false
        }
        """#
    )

    /// The cards worth reading — a blank card holds nothing — and, when
    /// keywords are given, those whose keyword starts with one (QA M17).
    static func cards(of header: FITSHeader, keywords: [String]?) -> (all: [FITSCard], chosen: [FITSCard]) {
        let all = header.orderedCards.filter { !$0.keyword.isEmpty || !$0.value.allSatisfy(\.isWhitespace) }
        let prefixes = (keywords ?? []).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        guard !prefixes.isEmpty else { return (all, all) }
        return (all, all.filter { card in prefixes.contains { card.keyword.hasPrefix($0) } })
    }

    /// Closure resolves the observation id (full UUID or unique hex
    /// prefix) to a *security-scoped* FITSFile snapshot.
    let resolve: @Sendable (_ id: String) async throws -> ResolvedFITS?

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard let resolved = try await resolve(args.downloaded_observation_id) else {
            throw ToolFailureReason.observationNotFound(id: args.downloaded_observation_id, localPath: nil)
        }
        let hduIndex: Int
        let hdu: FITSHDUnit
        if let requested = args.hduIndex {
            guard requested >= 0, requested < resolved.file.hdus.count else {
                throw ToolFailureReason.invalidArgument(
                    "hduIndex \(requested) out of range [0, \(resolved.file.hdus.count - 1)]"
                )
            }
            hduIndex = requested
            hdu = resolved.file.hdus[requested]
        } else {
            guard let firstImage = resolved.file.firstImageHDU else {
                throw ToolFailureReason.backendError("file has no image HDU")
            }
            hduIndex = firstImage.id
            hdu = firstImage
        }
        let (all, chosen) = Self.cards(of: hdu.header, keywords: args.keywords)
        return Output(
            observationID: resolved.observationID,
            hduIndex: hduIndex,
            totalCards: all.count,
            cards: chosen.map { Output.Card(keyword: $0.keyword, value: $0.value, comment: $0.comment) }
        )
    }
}

// MARK: - get_fits_wcs

/// Pixel↔world transform parameters for a FITS HDU.
struct GetFITSWCSTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let downloaded_observation_id: String
        var hduIndex: Int?
    }

    struct Output: Encodable, Sendable {
        let observationID: String
        let hduIndex: Int
        /// Why this HDU: `requested`, `onScreen`, `firstWithWCS` or `firstImage`.
        let hduChosenBy: String
        let hasWCS: Bool
        let isApproximate: Bool
        let projection: String?
        let crpix1: Double?
        let crpix2: Double?
        let crval1Deg: Double?
        let crval2Deg: Double?
        let pixelScaleArcsec: Double?
        let northAngleDeg: Double?
        let hasParityFlip: Bool?
        let ctype1: String?
        let ctype2: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_fits_wcs",
        description: "Return parsed WCS (CRPIX/CRVAL, projection, pixel scale, north angle, parity flip) for one HDU of a previously-downloaded observation. Argument is the `downloaded_observation_id` UUID, not a `publisher_id` — file must already be on disk. Without `hduIndex` it reads the HDU on screen when the file is open in the FITS Viewer, otherwise the first HDU with a WCS (an HST file's primary HDU has none); `hduChosenBy` says which.",
        schema: #"""
        {
          "type": "object",
          "required": ["downloaded_observation_id"],
          "properties": {
            "downloaded_observation_id": { "type": "string" },
            "hduIndex": { "type": "integer", "minimum": 0 }
          },
          "additionalProperties": false
        }
        """#
    )

    let resolve: @Sendable (_ id: String) async throws -> ResolvedFITS?
    /// The HDU the FITS Viewer shows for this file, when it is open.
    var onScreenHDU: @Sendable (_ file: URL) async -> Int? = { _ in nil }

    /// Which HDU to read when none is named: the one on screen, else the
    /// first with a WCS, else the first image.
    static func defaultHDU(in file: FITSFile, onScreen: Int?) -> (hdu: FITSHDUnit, chosenBy: String)? {
        if let onScreen, file.hdus.indices.contains(onScreen) {
            return (file.hdus[onScreen], "onScreen")
        }
        if let withWCS = file.hdus.first(where: { $0.wcs != nil }) {
            return (withWCS, "firstWithWCS")
        }
        return file.firstImageHDU.map { ($0, "firstImage") }
    }

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard let resolved = try await resolve(args.downloaded_observation_id) else {
            throw ToolFailureReason.observationNotFound(id: args.downloaded_observation_id, localPath: nil)
        }
        let hdu: FITSHDUnit
        let chosenBy: String
        if let requested = args.hduIndex {
            guard requested >= 0, requested < resolved.file.hdus.count else {
                throw ToolFailureReason.invalidArgument(
                    "hduIndex \(requested) out of range [0, \(resolved.file.hdus.count - 1)]"
                )
            }
            (hdu, chosenBy) = (resolved.file.hdus[requested], "requested")
        } else {
            let onScreen = await onScreenHDU(resolved.file.url)
            guard let chosen = Self.defaultHDU(in: resolved.file, onScreen: onScreen) else {
                throw ToolFailureReason.backendError("file has no image HDU")
            }
            (hdu, chosenBy) = chosen
        }
        let hduIndex = hdu.id
        guard let wcs = hdu.wcs else {
            return Output(
                observationID: resolved.observationID,
                hduIndex: hduIndex,
                hduChosenBy: chosenBy,
                hasWCS: false,
                isApproximate: false,
                projection: nil,
                crpix1: nil, crpix2: nil,
                crval1Deg: nil, crval2Deg: nil,
                pixelScaleArcsec: nil,
                northAngleDeg: nil,
                hasParityFlip: nil,
                ctype1: nil, ctype2: nil
            )
        }
        return Output(
            observationID: resolved.observationID,
            hduIndex: hduIndex,
            hduChosenBy: chosenBy,
            hasWCS: true,
            isApproximate: wcs.isApproximate,
            projection: "\(wcs.projection)",
            crpix1: wcs.crpix1,
            crpix2: wcs.crpix2,
            crval1Deg: wcs.crval1,
            crval2Deg: wcs.crval2,
            pixelScaleArcsec: wcs.pixelScaleArcsec,
            northAngleDeg: wcs.northAngle,
            hasParityFlip: wcs.hasParityFlip,
            ctype1: wcs.ctype1,
            ctype2: wcs.ctype2
        )
    }
}

// MARK: - DTO

/// Parsed FITS file plus its observation context. Returned by the
/// AppState resolver closure with security-scoped access already in
/// hand (caller has invoked startAccessingSecurityScopedResource).
struct ResolvedFITS: Sendable {
    let observationID: String
    let file: FITSFile
}
