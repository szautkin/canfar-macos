// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Top-level ADQL query builder orchestrator.
/// Calls all domain builders and assembles the full ADQL query.
enum ADQLBuilder {

    /// Build a complete ADQL query from the search form state.
    static func buildQuery(
        formState: SearchFormState,
        resolverCoords: (ra: String, dec: String)?
    ) -> String {
        var allClauses: [String] = []

        // Observation text constraints
        let observationValues: [String: String] = [
            "Observation.observationID": formState.observationID,
            "Observation.proposal.pi": formState.piName,
            "Observation.proposal.id": formState.proposalID,
            "Observation.proposal.title": formState.proposalTitle,
            "Observation.proposal.keywords": formState.proposalKeywords,
        ]
        allClauses += ObservationBuilder.buildWhere(values: observationValues)

        // Spatial constraints
        allClauses += SpatialBuilder.buildWhere(SpatialBuilder.Params(
            target: formState.target,
            resolver: formState.resolver,
            resolverCoords: resolverCoords,
            pixelScale: formState.pixelScale
        ))

        // Temporal constraints
        allClauses += TemporalBuilder.buildWhere(
            date: formState.observationDate,
            preset: formState.datePreset,
            exposure: formState.integrationTime,
            timeSpan: formState.timeSpan
        )

        // Spectral constraints
        allClauses += SpectralBuilder.buildWhere(
            coverage: formState.spectralCoverage,
            sampling: formState.spectralSampling,
            resolvingPower: formState.resolvingPower,
            bandpassWidth: formState.bandpassWidth,
            restFrameEnergy: formState.restFrameEnergy
        )

        // Data train constraints
        let dataTrainSelections: [String: [String]] = [
            "Plane.energy.emBand": formState.selectedBands,
            "Observation.collection": formState.selectedCollections,
            "Observation.instrument.name": formState.selectedInstruments,
            "Plane.energy.bandpassName": formState.selectedFilters,
            "Plane.calibrationLevel": formState.selectedCalLevels,
            "Plane.dataProductType": formState.selectedDataTypes,
            "Observation.type": formState.selectedObsTypes,
        ]
        allClauses += DataTrainBuilder.buildWhere(selections: dataTrainSelections)

        // Intent
        if let intentClause = MiscBuilder.buildIntentClause(formState.intent) {
            allClauses.append(intentClause)
        }

        // Public only
        if let publicClause = MiscBuilder.buildPublicOnlyClause(formState.publicOnly) {
            allClauses.append(publicClause)
        }

        // Data release date
        if let releaseClause = MiscBuilder.buildDataReleaseClause(formState.dataRelease) {
            allClauses.append(releaseClause)
        }

        // Always add quality filter
        allClauses.append(ADQL.qualityFilter)

        // Assemble
        let select = "SELECT " + ADQL.selectColumns.joined(separator: ",\n       ")
        let from = "FROM " + ADQL.fromClause
        let whereClause = allClauses.joined(separator: "\nAND ")

        return "\(select)\n\(from)\nWHERE \(whereClause)"
    }
}
