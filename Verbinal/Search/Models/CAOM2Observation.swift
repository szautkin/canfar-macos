// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Domain model for the CAOM-2 observation document returned by
/// `caom2ops/meta?ID=caom:{collection}/{observationID}`.
///
/// Modelled at the level of detail the result-table detail viewer cares
/// about — full Chunk-level WCS axis descriptions are deliberately omitted;
/// the upstream XML carries them but no UI needs them yet. New fields can
/// be added without breaking the parser (parser ignores unknown elements).
struct CAOM2Observation: Equatable, Sendable {
    let collection: String
    let observationID: String
    let observationType: String?         // e.g. "OBJECT" / "DARK"
    let intent: String?                  // "science" | "calibration"
    let sequenceNumber: String?
    let metaRelease: Date?
    let algorithm: String?               // "exposure" / "coadd" / ...

    let proposal: Proposal?
    let target: Target?
    let telescope: Telescope?
    let instrument: Instrument?
    let environment: Environment?

    let planes: [Plane]
}

extension CAOM2Observation {
    struct Proposal: Equatable, Sendable {
        let id: String?
        let pi: String?
        let project: String?
        let title: String?
        let keywords: [String]
    }

    struct Target: Equatable, Sendable {
        let name: String?
        let type: String?
        let standard: Bool?
        let redshift: Double?
        let moving: Bool?
        let keywords: [String]
    }

    struct Telescope: Equatable, Sendable {
        let name: String?
        /// Geocentric ITRF (X, Y, Z) in metres. Often the only telescope
        /// position info available; useful for displaying observatory site.
        let geoLocation: (x: Double, y: Double, z: Double)?
        let keywords: [String]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name
                && lhs.geoLocation?.x == rhs.geoLocation?.x
                && lhs.geoLocation?.y == rhs.geoLocation?.y
                && lhs.geoLocation?.z == rhs.geoLocation?.z
                && lhs.keywords == rhs.keywords
        }
    }

    struct Instrument: Equatable, Sendable {
        let name: String?
        let keywords: [String]
    }

    struct Environment: Equatable, Sendable {
        let seeing: Double?
        let humidity: Double?
        let elevation: Double?
        let tau: Double?
        let wavelengthTau: Double?
        let ambientTemp: Double?
        let photometric: Bool?
    }

    struct Plane: Equatable, Sendable {
        let productID: String
        let creatorID: String?
        let metaRelease: Date?
        let dataRelease: Date?
        let dataProductType: String?      // image / spectrum / cube / ...
        let calibrationLevel: Int?

        let provenance: Provenance?
        let metrics: Metrics?
        let quality: String?              // junk / good / etc.

        let position: Position?
        let energy: Energy?
        let time: Time?
        let polarization: Polarization?

        let artifacts: [Artifact]
    }

    struct Provenance: Equatable, Sendable {
        let name: String?
        let version: String?
        let project: String?
        let producer: String?
        let runID: String?
        let reference: String?
        let lastExecuted: Date?
        let keywords: [String]
        /// Plane URIs of upstream observations (`ivo://...?obs/prod`).
        let inputs: [String]
    }

    struct Metrics: Equatable, Sendable {
        let sourceNumberDensity: Double?
        let background: Double?
        let backgroundStddev: Double?
        let fluxDensityLimit: Double?
        let magLimit: Double?
        let sampleSNR: Double?
    }

    /// Spatial coverage. `polygon` carries the footprint outline as
    /// (RA, Dec) vertex pairs in degrees — suitable for sky-map drawing.
    struct Position: Equatable, Sendable {
        let polygon: [(ra: Double, dec: Double)]
        let dimensionPixels: (naxis1: Int, naxis2: Int)?
        let resolutionArcsec: Double?
        let sampleSizeArcsec: Double?
        let timeDependent: Bool?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.polygon.count == rhs.polygon.count
                && zip(lhs.polygon, rhs.polygon).allSatisfy { $0.ra == $1.ra && $0.dec == $1.dec }
                && lhs.dimensionPixels?.naxis1 == rhs.dimensionPixels?.naxis1
                && lhs.dimensionPixels?.naxis2 == rhs.dimensionPixels?.naxis2
                && lhs.resolutionArcsec == rhs.resolutionArcsec
                && lhs.sampleSizeArcsec == rhs.sampleSizeArcsec
                && lhs.timeDependent == rhs.timeDependent
        }
    }

    /// Spectral coverage. Bounds in metres (TAP/CAOM2 native).
    struct Energy: Equatable, Sendable {
        let lowerMetres: Double?
        let upperMetres: Double?
        let resolvingPower: Double?
        let bandpassName: String?
        let emBand: String?
        let restWavMetres: Double?
    }

    /// Temporal coverage. Bounds in MJD; exposure in seconds.
    struct Time: Equatable, Sendable {
        let lowerMJD: Double?
        let upperMJD: Double?
        let exposureSeconds: Double?
    }

    struct Polarization: Equatable, Sendable {
        /// Stokes states present. Free-form ("I", "Q", "U", "V", "RR", ...).
        let states: [String]
    }

    struct Artifact: Equatable, Sendable {
        let uri: String                  // cadc:NEOSSAT/NEOS_SCI_..._cor.fits
        let productType: String?         // science / weight / preview / aux
        let releaseType: String?         // data / meta
        let contentLength: Int64?
        let contentType: String?
        let contentChecksum: String?
    }
}

// MARK: - URI helpers

extension CAOM2Observation {
    /// Convert a publisher URI (`ivo://cadc.nrc.ca/{collection}?{observationID}`)
    /// to the CAOM2 observation URI form (`caom:{collection}/{observationID}`)
    /// expected by the metadata service.
    ///
    /// Returns `nil` if the input doesn't look like a publisher URI.
    static func observationURI(fromPublisherID publisherID: String) -> String? {
        // Form: ivo://<authority>/<collection>?<observationID>[/<productID>]
        guard let url = URL(string: publisherID),
              let scheme = url.scheme?.lowercased(), scheme == "ivo" else { return nil }
        let path = url.path
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let collection = pieces.first, !collection.isEmpty else { return nil }

        // observationID is the URL "query" part of the publisher URI; productID
        // (if present) follows a `/` after it. Strip the productID for an
        // observation-level URI.
        let queryPart = url.query ?? ""
        let observationID = queryPart.split(separator: "/", maxSplits: 1).first.map(String.init) ?? queryPart
        guard !observationID.isEmpty else { return nil }
        return "caom:\(collection)/\(observationID)"
    }
}
