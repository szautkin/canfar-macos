// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Run a CADC TAP query.
///
/// Two parameter styles, mutually exclusive:
///   * `adql` — raw ADQL the agent constructed itself.
///   * `target` + optional `radiusDeg` (or `ra`/`dec` + radius) — convenience
///     form the tool turns into a `CONTAINS(POINT, CIRCLE)` ADQL fragment.
///
/// `maxRec` is capped at 1000 to defend the public TAP backend; agents are
/// asked to refine queries rather than slurp everything.
struct SearchObservationsTool: JSONReadTool {

    struct Args: Decodable, Sendable {
        var adql: String?
        var target: String?
        var ra: Double?
        var dec: Double?
        var radiusDeg: Double?
        var maxRec: Int?
    }

    struct Output: Encodable, Sendable {
        let headers: [String]
        let rows: [[String]]
        let truncated: Bool
        let adqlExecuted: String
        /// The header of the column that holds each row's publisher ID.
        let identifierColumn: String?
        /// Each row's publisher ID, in row order; null for a row without one
        /// (plan 54 D1).
        let publisherIDs: [String?]
        /// What identifies the rows, what was added, or why they have no publisher ID.
        let identifier: IdentifierReport
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "search_observations",
        description: "Query the CADC archive via TAP. Either pass `adql` directly, or `target` (or `ra`+`dec`) plus `radiusDeg` for a positional cone search (CIRCLE+INTERSECTS against `Plane.position_bounds`; default radius 0.05°). Results: column headers + rows, and `publisherIDs`, each row's publisher ID in row order: what `get_preview_image`, `get_data_links`, `get_observation_caom2` and `download_observation` take. A query of products always returns it: when your ADQL does not select caom2.Plane.publisherID (or ivoa.ObsCore.obs_publisher_did), it is added as `\"Publisher ID\"`, and `identifier.added` says so (`adqlExecuted` is the query as run). A query whose rows are not products — DISTINCT, GROUP BY, aggregates, caom2.Observation alone — says why in `identifier.note`, with the JOIN that gives each row its product in `identifier.join`; rows of caom2.Observation get their `observationURI`, which get_observation_caom2 takes. Server-side cap of 1000 rows per call; set `maxRec` lower for narrow queries. TAP can stall 30–60s under cluster load: the archive is given \(Int(RequestTimeout.standard)) s to answer, and a search it does not answer in that time is not asked again.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "adql":      { "type": "string",  "description": "Raw ADQL. Mutually exclusive with the cone-search params." },
            "target":    { "type": "string",  "description": "Target name; resolved server-side to RA/Dec." },
            "ra":        { "type": "number",  "description": "RA in degrees (J2000)." },
            "dec":       { "type": "number",  "description": "Dec in degrees (J2000)." },
            "radiusDeg": { "type": "number",  "description": "Cone-search radius in degrees. Default 0.05° (~3 arcmin)." },
            "maxRec":    { "type": "integer", "minimum": 1, "maximum": 1000,
                           "description": "Hard cap 1000. Defaults to 100." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Closure-injected so the tool can be tested without a live TAPClient.
    let runQuery: @Sendable (_ adql: String, _ maxRec: Int) async throws -> (headers: [String], rows: [[String]])
    /// Closure-injected resolver for the `target` convenience form.
    let resolveTarget: @Sendable (_ name: String) async throws -> (ra: Double, dec: Double)
    /// The archive's schema when it is known, to find each table's
    /// identifier by meaning; without it, the archive's own tables are known.
    var schema: @Sendable () async -> TapSchema? = { nil }

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let maxRec = min(max(args.maxRec ?? 100, 1), 1000)
        let checked = ADQLIdentifier.ensure(try await composeADQL(args, maxRec: maxRec), schema: await schema())
        let result = try await runQuery(checked.adql, maxRec)
        let column = result.headers.firstIndex { ResultIdentifier.of(header: $0) == .product }
        return Output(
            headers: result.headers,
            rows: result.rows,
            truncated: result.rows.count == maxRec,
            adqlExecuted: checked.adql,
            identifierColumn: column.map { result.headers[$0] },
            publisherIDs: result.rows.map { row in
                column.flatMap { row.indices.contains($0) && !row[$0].isEmpty ? row[$0] : nil }
            },
            identifier: IdentifierReport(checked)
        )
    }

    /// The query that runs: the agent's own, or a cone of `maxRec` rows at most,
    /// so `adqlExecuted` says what ran (plan 36 1.2).
    func composeADQL(_ args: Args, maxRec: Int) async throws -> String {
        if let adql = args.adql, !adql.isEmpty {
            return adql
        }
        let radius = args.radiusDeg ?? 0.05
        let ra: Double
        let dec: Double
        if let r = args.ra, let d = args.dec {
            ra = r; dec = d
        } else if let target = args.target, !target.isEmpty {
            do {
                let coords = try await resolveTarget(target)
                ra = coords.ra
                dec = coords.dec
            } catch let f as ToolFailureReason {
                // Preserve typed reason from the resolver (e.g.,
                // targetNotResolved) instead of collapsing to a
                // generic unknownTarget.
                throw f
            } catch {
                throw ToolFailureReason.targetNotResolved(target)
            }
        } else {
            throw ToolFailureReason.invalidArgument("Provide one of: adql, target, or (ra+dec).")
        }
        // Cone search ADQL: any plane whose footprint intersects the
        // CIRCLE around (ra, dec). Earlier version used `POINT` here
        // and never inserted `radius` — the caller's `radiusDeg`
        // was silently ignored, so cone searches collapsed to a
        // centroid-exact match (rare hit). Now `radius` is part of
        // the geometry; agents wanting more shape control still
        // pass `adql` directly.
        return """
        SELECT TOP \(maxRec)
          Observation.collection,
          Observation.observationID,
          Plane.publisherID AS publisher_id,
          Observation.target_name,
          Observation.instrument_name,
          Plane.energy_bandpassName AS filter,
          COORD1(CENTROID(Plane.position_bounds)) AS ra_deg,
          COORD2(CENTROID(Plane.position_bounds)) AS dec_deg,
          Plane.calibrationLevel,
          Plane.dataProductType
        FROM caom2.Plane AS Plane
        JOIN caom2.Observation AS Observation ON Plane.obsID = Observation.obsID
        WHERE
          1 = INTERSECTS(
            CIRCLE('ICRS', \(ra), \(dec), \(radius)),
            Plane.position_bounds
          )
          AND ( Plane.quality_flag IS NULL OR Plane.quality_flag != 'junk' )
        """
    }
}
