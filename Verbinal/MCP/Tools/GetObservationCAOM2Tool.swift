// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Fetch the full CAOM-2 metadata document for a single observation.
///
/// Returns a lossy projection (the upstream XML is ~10× larger than what
/// any UI surfaces). Agents that need the raw XML can request the
/// publisher_id alongside this response and fetch it themselves.
struct GetObservationCAOM2Tool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let publisher_id: String
    }

    struct Output: Encodable, Sendable {
        let collection: String
        let observationID: String
        let observationType: String?
        let intent: String?
        let sequenceNumber: String?
        let metaReleaseISO: String?
        let algorithm: String?
        let proposal: ProposalOut?
        let target: TargetOut?
        let telescope: TelescopeOut?
        let instrument: InstrumentOut?
        let environment: EnvironmentOut?
        let planes: [PlaneOut]

        struct ProposalOut: Encodable, Sendable {
            let id: String?; let pi: String?; let project: String?
            let title: String?; let keywords: [String]
        }
        struct TargetOut: Encodable, Sendable {
            let name: String?; let type: String?
            let standard: Bool?; let redshift: Double?
            let moving: Bool?; let keywords: [String]
        }
        struct TelescopeOut: Encodable, Sendable {
            let name: String?
            let geoX: Double?; let geoY: Double?; let geoZ: Double?
            let keywords: [String]
        }
        struct InstrumentOut: Encodable, Sendable {
            let name: String?; let keywords: [String]
        }
        struct EnvironmentOut: Encodable, Sendable {
            let seeing: Double?; let humidity: Double?
            let elevation: Double?; let tau: Double?
            let wavelengthTau: Double?; let ambientTemp: Double?
            let photometric: Bool?
        }
        struct PlaneOut: Encodable, Sendable {
            let productID: String
            let dataProductType: String?
            let calibrationLevel: Int?
            let metaReleaseISO: String?
            let dataReleaseISO: String?
            let provenanceName: String?
            let provenanceVersion: String?
            let energyLowerMetres: Double?
            let energyUpperMetres: Double?
            let energyBandpassName: String?
            let energyEMBand: String?
            let timeLowerMJD: Double?
            let timeUpperMJD: Double?
            let exposureSeconds: Double?
            let polarizationStates: [String]
            let positionPolygon: [[Double]]
            let resolutionArcsec: Double?
            let sampleSizeArcsec: Double?
            let artifacts: [ArtifactOut]
        }
        struct ArtifactOut: Encodable, Sendable {
            let uri: String
            let productType: String?
            let releaseType: String?
            let contentLength: Int64?
            let contentType: String?
            let contentChecksum: String?
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_observation_caom2",
        description: "Fetch full CAOM-2 metadata for a CADC observation by publisher_id (e.g. 'ivo://cadc.nrc.ca/JWST?jw01147'). Cached for ~5 minutes.",
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

    /// Closure that fetches the CAOM2Observation; tool maps it to the
    /// flat encodable shape above so callers don't have to depend on
    /// VerbinalKit's domain types.
    let fetch: @Sendable (_ publisherID: String) async throws -> CAOM2Observation

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        do {
            let obs = try await fetch(args.publisher_id)
            return Self.flatten(obs)
        } catch {
            // Map known failures into typed reasons.
            let message = "\(error)"
            if message.contains("authenticationRequired") { throw ToolFailureReason.authRequired }
            if message.contains("observationNotFound") {
                throw ToolFailureReason.unknownTarget(args.publisher_id)
            }
            throw ToolFailureReason.backendError(message)
        }
    }

    private static func flatten(_ o: CAOM2Observation) -> Output {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let proposal = o.proposal.map {
            Output.ProposalOut(id: $0.id, pi: $0.pi, project: $0.project,
                               title: $0.title, keywords: $0.keywords)
        }
        let target = o.target.map {
            Output.TargetOut(name: $0.name, type: $0.type,
                             standard: $0.standard, redshift: $0.redshift,
                             moving: $0.moving, keywords: $0.keywords)
        }
        let telescope = o.telescope.map { t in
            Output.TelescopeOut(
                name: t.name,
                geoX: t.geoLocation?.x, geoY: t.geoLocation?.y, geoZ: t.geoLocation?.z,
                keywords: t.keywords
            )
        }
        let instrument = o.instrument.map {
            Output.InstrumentOut(name: $0.name, keywords: $0.keywords)
        }
        let environment = o.environment.map {
            Output.EnvironmentOut(
                seeing: $0.seeing, humidity: $0.humidity,
                elevation: $0.elevation, tau: $0.tau,
                wavelengthTau: $0.wavelengthTau, ambientTemp: $0.ambientTemp,
                photometric: $0.photometric
            )
        }
        let planes = o.planes.map { p -> Output.PlaneOut in
            let polygon: [[Double]] = (p.position?.polygon ?? []).map { [$0.ra, $0.dec] }
            let artifacts = p.artifacts.map {
                Output.ArtifactOut(
                    uri: $0.uri, productType: $0.productType,
                    releaseType: $0.releaseType, contentLength: $0.contentLength,
                    contentType: $0.contentType, contentChecksum: $0.contentChecksum
                )
            }
            return Output.PlaneOut(
                productID: p.productID,
                dataProductType: p.dataProductType,
                calibrationLevel: p.calibrationLevel,
                metaReleaseISO: p.metaRelease.map { iso.string(from: $0) },
                dataReleaseISO: p.dataRelease.map { iso.string(from: $0) },
                provenanceName: p.provenance?.name,
                provenanceVersion: p.provenance?.version,
                energyLowerMetres: p.energy?.lowerMetres,
                energyUpperMetres: p.energy?.upperMetres,
                energyBandpassName: p.energy?.bandpassName,
                energyEMBand: p.energy?.emBand,
                timeLowerMJD: p.time?.lowerMJD,
                timeUpperMJD: p.time?.upperMJD,
                exposureSeconds: p.time?.exposureSeconds,
                polarizationStates: p.polarization?.states ?? [],
                positionPolygon: polygon,
                resolutionArcsec: p.position?.resolutionArcsec,
                sampleSizeArcsec: p.position?.sampleSizeArcsec,
                artifacts: artifacts
            )
        }

        return Output(
            collection: o.collection,
            observationID: o.observationID,
            observationType: o.observationType,
            intent: o.intent,
            sequenceNumber: o.sequenceNumber,
            metaReleaseISO: o.metaRelease.map { iso.string(from: $0) },
            algorithm: o.algorithm,
            proposal: proposal,
            target: target,
            telescope: telescope,
            instrument: instrument,
            environment: environment,
            planes: planes
        )
    }
}
