// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Cone-search a VizieR catalogue at CDS. Closes the recurring
/// "I want all known variables within N arcmin of M71 from
/// catalogue V/97" pattern that the 2026-05-14 QA review named —
/// previously every agent had to write the CDS TAP boilerplate
/// from scratch. Public, no auth, completes inside the standard
/// TAP retry window.
///
/// Different VizieR catalogues use different column names for
/// position. The default RAJ2000 / DEJ2000 covers the majority
/// of holdings (Clement+2001 V/97, OGLE, ASAS-SN, ZTF). Override
/// per-catalogue when needed.
struct VizierConeSearchTool: JSONReadTool {
    // 90s deadline accommodates the multi-host VizieR fallback
    // chain (CDS-unistra → CDS-u-strasbg → ESAC → China-VO).
    // Each host gets up to ~20s before fallback rotates to the
    // next; 90s is enough for two-host fallback under bad weather
    // without false-positives on a slow-but-working primary host.
    var toolTimeoutSeconds: TimeInterval { 90 }

    struct Args: Decodable, Sendable {
        let catalogue: String
        let raDeg: Double
        let decDeg: Double
        let radiusArcsec: Double
        var raColumn: String?
        var decColumn: String?
        var maxRec: Int?
    }

    struct Output: Encodable, Sendable {
        let catalogue: String
        let headers: [String]
        let rows: [[String]]
        let rowCount: Int
        /// True when the row count equals the requested `maxRec`,
        /// meaning the server probably had more matches and the
        /// caller may want to widen `maxRec` or narrow the cone.
        let probablyTruncated: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "vizier_cone_search",
        description: "Cone-search a VizieR catalogue at CDS. Standard pattern for catalogue cross-matches against any of VizieR's many holdings (Clement+2001 variables-in-globular-clusters as V/97, OGLE catalogues, ASAS-SN, ZTF, etc.). Public, no auth. `catalogue` is the VizieR identifier exactly (`V/97/catalog`, `B/vsx/vsx`, `I/355/gaiadr3`, …). Position columns default to RAJ2000 / DEJ2000 — override `raColumn` / `decColumn` if the specific catalogue uses different names. `radiusArcsec` is in arcseconds for the convenience of typical cluster work; the tool converts to degrees internally. Returns parsed rows + a `probablyTruncated` hint when the row count hit the cap.",
        schema: #"""
        {
          "type": "object",
          "required": ["catalogue", "raDeg", "decDeg", "radiusArcsec"],
          "properties": {
            "catalogue":    { "type": "string", "minLength": 1, "description": "VizieR catalogue identifier, e.g. V/97/catalog." },
            "raDeg":        { "type": "number" },
            "decDeg":       { "type": "number" },
            "radiusArcsec": { "type": "number", "minimum": 0, "description": "Cone radius in arcseconds; converted to degrees internally." },
            "raColumn":     { "type": "string", "description": "Override the RA column name. Default: RAJ2000." },
            "decColumn":    { "type": "string", "description": "Override the Dec column name. Default: DEJ2000." },
            "maxRec":       { "type": "integer", "minimum": 1, "maximum": 5000, "description": "Row cap; default 500." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Closure shape so the tool doesn't depend on TAPClient directly.
    /// Mirrors `search_observations` and friends.
    let search: @Sendable (
        _ catalogue: String,
        _ raDeg: Double,
        _ decDeg: Double,
        _ radiusDeg: Double,
        _ raColumn: String,
        _ decColumn: String,
        _ maxRec: Int
    ) async throws -> (headers: [String], rows: [[String]])

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let maxRec = args.maxRec ?? 500
        let raCol = args.raColumn ?? "RAJ2000"
        let decCol = args.decColumn ?? "DEJ2000"
        let radiusDeg = args.radiusArcsec / 3600.0
        do {
            let (headers, rows) = try await search(
                args.catalogue, args.raDeg, args.decDeg, radiusDeg,
                raCol, decCol, maxRec
            )
            return Output(
                catalogue: args.catalogue,
                headers: headers,
                rows: rows,
                rowCount: rows.count,
                probablyTruncated: rows.count >= maxRec
            )
        } catch {
            throw ToolFailureReason.backendError("vizier_cone_search: \(error.localizedDescription)")
        }
    }
}
