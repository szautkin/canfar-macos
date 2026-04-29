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
    }

    struct Output: Encodable, Sendable {
        let observationID: String
        let hduIndex: Int
        let cards: [Card]
        struct Card: Encodable, Sendable {
            let keyword: String
            let value: String
            let comment: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_fits_header",
        description: "Return FITS header cards for one HDU of a downloaded observation. Defaults to the first image HDU.",
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

    /// Closure resolves the observation id to a *security-scoped*
    /// FITSFile snapshot. Implementation lives in AppState+AgentTools so
    /// the tool stays pure.
    let resolve: @Sendable (_ id: UUID) async throws -> ResolvedFITS?

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard let uuid = UUID(uuidString: args.downloaded_observation_id) else {
            throw ToolFailureReason.invalidArgument("downloaded_observation_id is not a UUID")
        }
        guard let resolved = try await resolve(uuid) else {
            throw ToolFailureReason.unknownTarget("downloaded_observation \(args.downloaded_observation_id)")
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
        let cards = hdu.header.orderedCards.map {
            Output.Card(keyword: $0.keyword, value: $0.value, comment: $0.comment)
        }
        return Output(
            observationID: resolved.observationID,
            hduIndex: hduIndex,
            cards: cards
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
        description: "Return parsed WCS (CRPIX/CRVAL, projection, pixel scale, north angle, parity flip) for one HDU of a downloaded observation.",
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

    let resolve: @Sendable (_ id: UUID) async throws -> ResolvedFITS?

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard let uuid = UUID(uuidString: args.downloaded_observation_id) else {
            throw ToolFailureReason.invalidArgument("downloaded_observation_id is not a UUID")
        }
        guard let resolved = try await resolve(uuid) else {
            throw ToolFailureReason.unknownTarget("downloaded_observation \(args.downloaded_observation_id)")
        }
        let hdu: FITSHDUnit
        let hduIndex: Int
        if let requested = args.hduIndex {
            guard requested >= 0, requested < resolved.file.hdus.count else {
                throw ToolFailureReason.invalidArgument(
                    "hduIndex \(requested) out of range [0, \(resolved.file.hdus.count - 1)]"
                )
            }
            hdu = resolved.file.hdus[requested]
            hduIndex = requested
        } else {
            guard let firstImage = resolved.file.firstImageHDU else {
                throw ToolFailureReason.backendError("file has no image HDU")
            }
            hdu = firstImage
            hduIndex = firstImage.id
        }
        guard let wcs = hdu.wcs else {
            return Output(
                observationID: resolved.observationID,
                hduIndex: hduIndex,
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
struct ResolvedFITS: @unchecked Sendable {
    let observationID: String
    let file: FITSFile
}
