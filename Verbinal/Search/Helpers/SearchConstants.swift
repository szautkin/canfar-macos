// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// MARK: - TAP Configuration

enum TAPConfig {
    static let baseURL = "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca"
    static let syncPath = "/argus/sync"
    static let resolverPath = "/cadc-target-resolver/find"
    static let datalinkPath = "/caom2ops/datalink"
    static let downloadPath = "/caom2ops/pkg"
    static let maxRecords = 30000
    static let format = "csv"
}

enum CADCExternalURLs {
    static let caom2uiView = "https://www.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/caom2ui/view"
    static let downloadManager = "https://www.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/downloadManager/download"
}

// MARK: - ADQL Constants

enum ADQL {

    static let selectColumns: [String] = [
        "isDownloadable(Plane.publisherID) AS \"Download\"",
        "Observation.observationURI AS \"Preview\"",
        "Plane.publisherID AS \"Publisher ID\"",
        "Observation.collection AS \"Collection\"",
        "Observation.sequenceNumber AS \"Sequence Number\"",
        "Plane.productID AS \"Product ID\"",
        "COORD1(CENTROID(Plane.position_bounds)) AS \"RA (J2000.0)\"",
        "COORD2(CENTROID(Plane.position_bounds)) AS \"Dec. (J2000.0)\"",
        "Observation.target_name AS \"Target Name\"",
        "Plane.time_bounds_lower AS \"Start Date\"",
        "Plane.time_exposure AS \"Int. Time\"",
        "Observation.instrument_name AS \"Instrument\"",
        "Plane.energy_bandpassName AS \"Filter\"",
        "Plane.calibrationLevel AS \"Cal. Lev.\"",
        "Observation.type AS \"Obs. Type\"",
        "Observation.proposal_id AS \"Proposal ID\"",
        "Observation.proposal_pi AS \"P.I. Name\"",
        "Plane.dataRelease AS \"Data Release\"",
        "Observation.observationID AS \"Obs. ID\"",
        "Plane.energy_bounds_lower AS \"Min. Wavelength\"",
        "Plane.energy_bounds_upper AS \"Max. Wavelength\"",
        "AREA(Plane.position_bounds) AS \"Field of View\"",
        "Plane.position_bounds AS \"Shape\"",
        "Plane.position_sampleSize AS \"Pixel Scale\"",
        "Plane.energy_resolvingPower AS \"Resolving Power\"",
        "Plane.time_bounds_upper AS \"End Date\"",
        "Plane.dataProductType AS \"Data Type\"",
        "Observation.target_moving AS \"Moving Target\"",
        "Plane.provenance_name AS \"Provenance Name\"",
        "Observation.intent AS \"Intent\"",
        "Observation.target_type AS \"Target Type\"",
        "Observation.target_standard AS \"Target Standard\"",
        "Observation.target_keywords AS \"Target Keywords\"",
        "Observation.algorithm_name AS \"Algorithm Name\"",
        "Observation.proposal_title AS \"Proposal Title\"",
        "Observation.proposal_keywords AS \"Proposal Keywords\"",
        "Plane.position_resolution AS \"IQ\"",
        "Observation.instrument_keywords AS \"Instrument Keywords\"",
        "Plane.energy_transition_species AS \"Molecule\"",
        "Plane.energy_transition_transition AS \"Transition\"",
        "Observation.proposal_project AS \"Proposal Project\"",
        "Plane.energy_emBand AS \"Band\"",
        "Plane.provenance_version AS \"Prov. Version\"",
        "Plane.provenance_project AS \"Prov. Project\"",
        "Plane.provenance_runID AS \"Prov. Run ID\"",
        "Plane.provenance_lastExecuted AS \"Prov. Last Executed\"",
        "Plane.energy_restwav AS \"Rest-frame Energy\"",
        "Observation.requirements_flag AS \"Quality\"",
    ]

    static let fromClause = "caom2.Plane AS Plane JOIN caom2.Observation AS Observation ON Plane.obsID = Observation.obsID"

    static let qualityFilter = "( Plane.quality_flag IS NULL OR Plane.quality_flag != 'junk' )"

    static let observationTAPColumns: [String: String] = [
        "Observation.observationID": "Observation.observationID",
        "Observation.proposal.pi": "Observation.proposal_pi",
        "Observation.proposal.id": "Observation.proposal_id",
        "Observation.proposal.title": "Observation.proposal_title",
        "Observation.proposal.keywords": "Observation.proposal_keywords",
    ]

    static let wildTextFields: Set<String> = [
        "Observation.proposal.pi",
        "Observation.proposal.id",
        "Observation.proposal.title",
        "Observation.proposal.keywords",
    ]

    static let exactTextFields: Set<String> = [
        "Observation.observationID",
    ]

    static let defaultSearchRadius = 1.0 / 60.0

    static let pixelScaleFactors: [String: Double] = [
        "arcsec": 1,
        "arcmin": 60,
        "deg": 3600,
    ]

    static let dataTrainObservationColumns: [String: String] = [
        "Plane.energy.emBand": "Plane.energy_emBand",
        "Observation.collection": "Observation.collection",
        "Observation.instrument.name": "Observation.instrument_name",
        "Plane.energy.bandpassName": "Plane.energy_bandpassName",
        "Plane.calibrationLevel": "Plane.calibrationLevel",
        "Plane.dataProductType": "Plane.dataProductType",
        "Observation.type": "Observation.type",
    ]

    static let dataTrainColumns: [String] = [
        "Plane.energy.emBand",
        "Observation.collection",
        "Observation.instrument.name",
        "Plane.energy.bandpassName",
        "Plane.calibrationLevel",
        "Plane.dataProductType",
        "Observation.type",
    ]

    static let dataTrainColumnLabels: [String: String] = [
        "Plane.energy.emBand": "Band",
        "Observation.collection": "Collection",
        "Observation.instrument.name": "Instrument",
        "Plane.energy.bandpassName": "Filter",
        "Plane.calibrationLevel": "Cal. Level",
        "Plane.dataProductType": "Data Type",
        "Observation.type": "Obs. Type",
    ]
}

// MARK: - Spatial TAP Column Mappings

enum SpatialTAPColumns {
    static let targetName = "Observation.target_name"
    static let positionBounds = "Plane.position_bounds"
    static let sampleSize = "Plane.position_sampleSize"
}

// MARK: - Spectral TAP Column Mappings

enum SpectralTAPColumns {
    static let boundsLower = "Plane.energy_bounds_lower"
    static let boundsUpper = "Plane.energy_bounds_upper"
    static let sampleSize = "Plane.energy_sampleSize"
    static let boundsWidth = "Plane.energy_bounds_width"
    static let restwav = "Plane.energy_restwav"
    static let resolvingPower = "Plane.energy_resolvingPower"
}

// MARK: - Temporal TAP Column Mappings

enum TemporalTAPColumns {
    static let timeBoundsSamples = "Plane.time_bounds_samples"
    static let timeExposure = "Plane.time_exposure"
    static let timeBoundsWidth = "Plane.time_bounds_width"
}
