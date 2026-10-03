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
    /// The cone's radius: degrees, or with a unit (5', 30 arcsec); 1′ when
    /// empty. A radius typed after the target takes precedence (plan 30 R1).
    var searchRadius = ""
    var pixelScale = ""
    /// Download only the part of each file within the search's circle —
    /// as CADC's search page offers. Not a constraint: it shapes downloads.
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
    /// Download only the search's wavelengths of each file that has them.
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
        !target.isEmpty || !pixelScale.isEmpty ||
        !observationDate.isEmpty || datePreset != .none ||
        !integrationTime.isEmpty || !timeSpan.isEmpty ||
        !spectralCoverage.isEmpty || !spectralSampling.isEmpty ||
        !resolvingPower.isEmpty || !bandpassWidth.isEmpty ||
        !restFrameEnergy.isEmpty ||
        !selectedBands.isEmpty || !selectedCollections.isEmpty ||
        !selectedInstruments.isEmpty || !selectedFilters.isEmpty ||
        !selectedCalLevels.isEmpty || !selectedDataTypes.isEmpty ||
        !selectedObsTypes.isEmpty
    }

    /// Clear all data-train selections strictly *after* the given column index.
    /// Changing an upstream data-train column invalidates downstream options,
    /// so each upstream change resets everything below it. Consolidated here
    /// so callers do one mutation call instead of looping with N per-field writes.
    ///
    /// Column indices follow ``DataTrainModel``'s cascade order:
    /// 0=bands, 1=collections, 2=instruments, 3=filters, 4=calLevels,
    /// 5=dataTypes, 6=obsTypes.
    func clearDataTrainCascade(after columnIndex: Int) {
        if columnIndex < 0 { selectedBands = [] }
        if columnIndex < 1 { selectedCollections = [] }
        if columnIndex < 2 { selectedInstruments = [] }
        if columnIndex < 3 { selectedFilters = [] }
        if columnIndex < 4 { selectedCalLevels = [] }
        if columnIndex < 5 { selectedDataTypes = [] }
        if columnIndex < 6 { selectedObsTypes = [] }
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
        searchRadius = ""
        pixelScale = ""
        observationDate = ""
        datePreset = .none
        integrationTime = ""
        timeSpan = ""
        spectralCoverage = ""
        spectralSampling = ""
        resolvingPower = ""
        bandpassWidth = ""
        restFrameEnergy = ""
        selectedBands = []
        selectedCollections = []
        selectedInstruments = []
        selectedFilters = []
        selectedCalLevels = []
        selectedDataTypes = []
        selectedObsTypes = []
    }
}
