// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

@Observable
final class SearchFormState {
    // Observation constraints
    var observationID = ""
    var piName = ""
    var proposalID = ""
    var proposalTitle = ""
    var proposalKeywords = ""
    var dataRelease = ""
    var publicOnly = false
    var intent: IntentValue = .any

    // Spatial constraints
    var target = ""
    var resolver: ResolverValue = .all
    var pixelScale = ""
    var spatialCutout = false

    // Temporal constraints
    var observationDate = ""
    var datePreset: DatePresetValue = .none
    var integrationTime = ""
    var timeSpan = ""

    // Spectral constraints
    var spectralCoverage = ""
    var spectralSampling = ""
    var resolvingPower = ""
    var bandpassWidth = ""
    var restFrameEnergy = ""
    var spectralCutout = false

    // Data train selections
    var selectedBands: [String] = []
    var selectedCollections: [String] = []
    var selectedInstruments: [String] = []
    var selectedFilters: [String] = []
    var selectedCalLevels: [String] = []
    var selectedDataTypes: [String] = []
    var selectedObsTypes: [String] = []

    var hasValues: Bool {
        !observationID.isEmpty || !piName.isEmpty || !proposalID.isEmpty ||
        !proposalTitle.isEmpty || !proposalKeywords.isEmpty || !dataRelease.isEmpty ||
        publicOnly || intent != .any ||
        !target.isEmpty || !pixelScale.isEmpty || spatialCutout ||
        !observationDate.isEmpty || datePreset != .none ||
        !integrationTime.isEmpty || !timeSpan.isEmpty ||
        !spectralCoverage.isEmpty || !spectralSampling.isEmpty ||
        !resolvingPower.isEmpty || !bandpassWidth.isEmpty ||
        !restFrameEnergy.isEmpty || spectralCutout ||
        !selectedBands.isEmpty || !selectedCollections.isEmpty ||
        !selectedInstruments.isEmpty || !selectedFilters.isEmpty ||
        !selectedCalLevels.isEmpty || !selectedDataTypes.isEmpty ||
        !selectedObsTypes.isEmpty
    }

    func reset() {
        observationID = ""
        piName = ""
        proposalID = ""
        proposalTitle = ""
        proposalKeywords = ""
        dataRelease = ""
        publicOnly = false
        intent = .any
        target = ""
        resolver = .all
        pixelScale = ""
        spatialCutout = false
        observationDate = ""
        datePreset = .none
        integrationTime = ""
        timeSpan = ""
        spectralCoverage = ""
        spectralSampling = ""
        resolvingPower = ""
        bandpassWidth = ""
        restFrameEnergy = ""
        spectralCutout = false
        selectedBands = []
        selectedCollections = []
        selectedInstruments = []
        selectedFilters = []
        selectedCalLevels = []
        selectedDataTypes = []
        selectedObsTypes = []
    }
}
