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
public struct CAOM2Observation: Equatable, Sendable {
    public let collection: String
    public let observationID: String
    public let observationType: String?         // e.g. "OBJECT" / "DARK"
    public let intent: String?                  // "science" | "calibration"
    public let sequenceNumber: String?
    public let metaRelease: Date?
    public let algorithm: String?               // "exposure" / "coadd" / ...

    public let proposal: Proposal?
    public let target: Target?
    public let telescope: Telescope?
    public let instrument: Instrument?
    public let environment: Environment?

    public let planes: [Plane]

    public init(
        collection: String,
        observationID: String,
        observationType: String?,
        intent: String?,
        sequenceNumber: String?,
        metaRelease: Date?,
        algorithm: String?,
        proposal: Proposal?,
        target: Target?,
        telescope: Telescope?,
        instrument: Instrument?,
        environment: Environment?,
        planes: [Plane]
    ) {
        self.collection = collection
        self.observationID = observationID
        self.observationType = observationType
        self.intent = intent
        self.sequenceNumber = sequenceNumber
        self.metaRelease = metaRelease
        self.algorithm = algorithm
        self.proposal = proposal
        self.target = target
        self.telescope = telescope
        self.instrument = instrument
        self.environment = environment
        self.planes = planes
    }
}

extension CAOM2Observation {
    public struct Proposal: Equatable, Sendable {
        public let id: String?
        public let pi: String?
        public let project: String?
        public let title: String?
        public let keywords: [String]

        public init(id: String?, pi: String?, project: String?, title: String?, keywords: [String]) {
            self.id = id
            self.pi = pi
            self.project = project
            self.title = title
            self.keywords = keywords
        }
    }

    public struct Target: Equatable, Sendable {
        public let name: String?
        public let type: String?
        public let standard: Bool?
        public let redshift: Double?
        public let moving: Bool?
        public let keywords: [String]

        public init(name: String?, type: String?, standard: Bool?, redshift: Double?, moving: Bool?, keywords: [String]) {
            self.name = name
            self.type = type
            self.standard = standard
            self.redshift = redshift
            self.moving = moving
            self.keywords = keywords
        }
    }

    public struct Telescope: Equatable, Sendable {
        public let name: String?
        /// Geocentric ITRF (X, Y, Z) in metres. Often the only telescope
        /// position info available; useful for displaying observatory site.
        public let geoLocation: (x: Double, y: Double, z: Double)?
        public let keywords: [String]

        public init(name: String?, geoLocation: (x: Double, y: Double, z: Double)?, keywords: [String]) {
            self.name = name
            self.geoLocation = geoLocation
            self.keywords = keywords
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name
                && lhs.geoLocation?.x == rhs.geoLocation?.x
                && lhs.geoLocation?.y == rhs.geoLocation?.y
                && lhs.geoLocation?.z == rhs.geoLocation?.z
                && lhs.keywords == rhs.keywords
        }
    }

    public struct Instrument: Equatable, Sendable {
        public let name: String?
        public let keywords: [String]

        public init(name: String?, keywords: [String]) {
            self.name = name
            self.keywords = keywords
        }
    }

    public struct Environment: Equatable, Sendable {
        public let seeing: Double?
        public let humidity: Double?
        public let elevation: Double?
        public let tau: Double?
        public let wavelengthTau: Double?
        public let ambientTemp: Double?
        public let photometric: Bool?

        public init(seeing: Double?, humidity: Double?, elevation: Double?, tau: Double?, wavelengthTau: Double?, ambientTemp: Double?, photometric: Bool?) {
            self.seeing = seeing
            self.humidity = humidity
            self.elevation = elevation
            self.tau = tau
            self.wavelengthTau = wavelengthTau
            self.ambientTemp = ambientTemp
            self.photometric = photometric
        }
    }

    public struct Plane: Equatable, Sendable {
        public let productID: String
        public let creatorID: String?
        public let metaRelease: Date?
        public let dataRelease: Date?
        public let dataProductType: String?      // image / spectrum / cube / ...
        public let calibrationLevel: Int?

        public let provenance: Provenance?
        public let metrics: Metrics?
        public let quality: String?              // junk / good / etc.

        public let position: Position?
        public let energy: Energy?
        public let time: Time?
        public let polarization: Polarization?

        public let artifacts: [Artifact]

        public init(
            productID: String,
            creatorID: String?,
            metaRelease: Date?,
            dataRelease: Date?,
            dataProductType: String?,
            calibrationLevel: Int?,
            provenance: Provenance?,
            metrics: Metrics?,
            quality: String?,
            position: Position?,
            energy: Energy?,
            time: Time?,
            polarization: Polarization?,
            artifacts: [Artifact]
        ) {
            self.productID = productID
            self.creatorID = creatorID
            self.metaRelease = metaRelease
            self.dataRelease = dataRelease
            self.dataProductType = dataProductType
            self.calibrationLevel = calibrationLevel
            self.provenance = provenance
            self.metrics = metrics
            self.quality = quality
            self.position = position
            self.energy = energy
            self.time = time
            self.polarization = polarization
            self.artifacts = artifacts
        }
    }

    public struct Provenance: Equatable, Sendable {
        public let name: String?
        public let version: String?
        public let project: String?
        public let producer: String?
        public let runID: String?
        public let reference: String?
        public let lastExecuted: Date?
        public let keywords: [String]
        /// Plane URIs of upstream observations (`ivo://...?obs/prod`).
        public let inputs: [String]

        public init(name: String?, version: String?, project: String?, producer: String?, runID: String?, reference: String?, lastExecuted: Date?, keywords: [String], inputs: [String]) {
            self.name = name
            self.version = version
            self.project = project
            self.producer = producer
            self.runID = runID
            self.reference = reference
            self.lastExecuted = lastExecuted
            self.keywords = keywords
            self.inputs = inputs
        }
    }

    public struct Metrics: Equatable, Sendable {
        public let sourceNumberDensity: Double?
        public let background: Double?
        public let backgroundStddev: Double?
        public let fluxDensityLimit: Double?
        public let magLimit: Double?
        public let sampleSNR: Double?

        public init(sourceNumberDensity: Double?, background: Double?, backgroundStddev: Double?, fluxDensityLimit: Double?, magLimit: Double?, sampleSNR: Double?) {
            self.sourceNumberDensity = sourceNumberDensity
            self.background = background
            self.backgroundStddev = backgroundStddev
            self.fluxDensityLimit = fluxDensityLimit
            self.magLimit = magLimit
            self.sampleSNR = sampleSNR
        }
    }

    /// Spatial coverage. `polygon` carries the footprint outline as
    /// (RA, Dec) vertex pairs in degrees — suitable for sky-map drawing.
    public struct Position: Equatable, Sendable {
        public let polygon: [(ra: Double, dec: Double)]
        public let dimensionPixels: (naxis1: Int, naxis2: Int)?
        public let resolutionArcsec: Double?
        public let sampleSizeArcsec: Double?
        public let timeDependent: Bool?

        public init(polygon: [(ra: Double, dec: Double)], dimensionPixels: (naxis1: Int, naxis2: Int)?, resolutionArcsec: Double?, sampleSizeArcsec: Double?, timeDependent: Bool?) {
            self.polygon = polygon
            self.dimensionPixels = dimensionPixels
            self.resolutionArcsec = resolutionArcsec
            self.sampleSizeArcsec = sampleSizeArcsec
            self.timeDependent = timeDependent
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
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
    public struct Energy: Equatable, Sendable {
        public let lowerMetres: Double?
        public let upperMetres: Double?
        public let resolvingPower: Double?
        public let bandpassName: String?
        public let emBand: String?
        public let restWavMetres: Double?

        public init(lowerMetres: Double?, upperMetres: Double?, resolvingPower: Double?, bandpassName: String?, emBand: String?, restWavMetres: Double?) {
            self.lowerMetres = lowerMetres
            self.upperMetres = upperMetres
            self.resolvingPower = resolvingPower
            self.bandpassName = bandpassName
            self.emBand = emBand
            self.restWavMetres = restWavMetres
        }
    }

    /// Temporal coverage. Bounds in MJD; exposure in seconds.
    public struct Time: Equatable, Sendable {
        public let lowerMJD: Double?
        public let upperMJD: Double?
        public let exposureSeconds: Double?

        public init(lowerMJD: Double?, upperMJD: Double?, exposureSeconds: Double?) {
            self.lowerMJD = lowerMJD
            self.upperMJD = upperMJD
            self.exposureSeconds = exposureSeconds
        }
    }

    public struct Polarization: Equatable, Sendable {
        /// Stokes states present. Free-form ("I", "Q", "U", "V", "RR", ...).
        public let states: [String]

        public init(states: [String]) {
            self.states = states
        }
    }

    public struct Artifact: Equatable, Sendable {
        public let uri: String                  // cadc:NEOSSAT/NEOS_SCI_..._cor.fits
        public let productType: String?         // science / weight / preview / aux
        public let releaseType: String?         // data / meta
        public let contentLength: Int64?
        public let contentType: String?
        public let contentChecksum: String?

        public init(uri: String, productType: String?, releaseType: String?, contentLength: Int64?, contentType: String?, contentChecksum: String?) {
            self.uri = uri
            self.productType = productType
            self.releaseType = releaseType
            self.contentLength = contentLength
            self.contentType = contentType
            self.contentChecksum = contentChecksum
        }
    }
}

// MARK: - URI helpers

extension CAOM2Observation {
    /// Convert a publisher URI to the CAOM2 observation URI form
    /// (`caom:{collection}/{observationID}`) expected by the metadata
    /// service. Accepts every shape we've seen TAP return, including:
    ///
    ///   * Plain Observation form: `ivo://cadc.nrc.ca/JWST?jw01147`
    ///   * Plane form (with trailing productID):
    ///     `ivo://cadc.nrc.ca/CFHT?729989/729989p`
    ///   * Mirror collections (HST/JWST in CADC's mirror layer):
    ///     `ivo://cadc.nrc.ca/JWST/mirror?jw01147`
    ///
    /// All three are normalised to the same `caom:JWST/jw01147` form.
    /// Returns `nil` if the input doesn't look like a publisher URI.
    /// (Closes F-7 from the 2026-04-29 platform review — agents
    /// pipelining `search_observations` rows into `get_observation_caom2`
    /// shouldn't trip on the Plane / mirror id shape.)
    public static func observationURI(fromPublisherID publisherID: String) -> String? {
        guard let url = URL(string: publisherID),
              let scheme = url.scheme?.lowercased(), scheme == "ivo" else { return nil }
        // Path may carry a `/mirror` segment for HST / JWST mirror
        // entries — strip it so the collection comes out right.
        let pieces = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.lowercased() != "mirror" }
        guard let collection = pieces.first, !collection.isEmpty else { return nil }

        // observationID is the URL "query" part of the publisher URI;
        // productID (if present) follows a `/` after it. Strip the
        // productID for an observation-level URI.
        let queryPart = url.query ?? ""
        let observationID = queryPart.split(separator: "/", maxSplits: 1).first.map(String.init) ?? queryPart
        guard !observationID.isEmpty else { return nil }
        return "caom:\(collection)/\(observationID)"
    }
}
