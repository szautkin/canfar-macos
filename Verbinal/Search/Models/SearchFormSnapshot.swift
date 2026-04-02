// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A Codable snapshot of all search form fields for persistence.
struct SearchFormSnapshot: Codable, Equatable {
    var observationID: String = ""
    var piName: String = ""
    var proposalID: String = ""
    var proposalTitle: String = ""
    var proposalKeywords: String = ""
    var dataRelease: String = ""
    var publicOnly: Bool = false
    var intent: String = ""
    var target: String = ""
    var resolver: String = "ALL"
    var pixelScale: String = ""
    var observationDate: String = ""
    var datePreset: String = ""
    var integrationTime: String = ""
    var timeSpan: String = ""
    var spectralCoverage: String = ""
    var spectralSampling: String = ""
    var resolvingPower: String = ""
    var bandpassWidth: String = ""
    var restFrameEnergy: String = ""
    var selectedBands: [String] = []
    var selectedCollections: [String] = []
    var selectedInstruments: [String] = []
    var selectedFilters: [String] = []
    var selectedCalLevels: [String] = []
    var selectedDataTypes: [String] = []
    var selectedObsTypes: [String] = []

    /// Generate a default name for this search snapshot.
    func autoName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        let timestamp = formatter.string(from: Date())

        if let first = selectedCollections.first, !first.isEmpty {
            return "\(first) \u{2014} \(timestamp)"
        }
        if !target.isEmpty {
            return "\(target) \u{2014} \(timestamp)"
        }
        return "Search \u{2014} \(timestamp)"
    }

    /// Summary of active filters for display in card.
    func filterSummary() -> String {
        var parts: [String] = []
        if !target.isEmpty { parts.append("Target: \(target)") }
        if !selectedCollections.isEmpty { parts.append("Collection: \(selectedCollections.joined(separator: ", "))") }
        if !observationDate.isEmpty { parts.append("Date: \(observationDate)") }
        if !observationID.isEmpty { parts.append("Obs ID: \(observationID)") }
        if !piName.isEmpty { parts.append("PI: \(piName)") }
        if !selectedInstruments.isEmpty { parts.append("Instrument: \(selectedInstruments.joined(separator: ", "))") }
        if intent != "" && intent != IntentValue.any.rawValue { parts.append("Intent: \(intent)") }
        if publicOnly { parts.append("Public only") }
        if parts.isEmpty { return "No filters" }
        return parts.joined(separator: " | ")
    }
}

// MARK: - SearchFormState ↔ Snapshot Conversion

extension SearchFormState {

    func toSnapshot() -> SearchFormSnapshot {
        SearchFormSnapshot(
            observationID: observationID,
            piName: piName,
            proposalID: proposalID,
            proposalTitle: proposalTitle,
            proposalKeywords: proposalKeywords,
            dataRelease: dataRelease,
            publicOnly: publicOnly,
            intent: intent.rawValue,
            target: target,
            resolver: resolver.rawValue,
            pixelScale: pixelScale,
            observationDate: observationDate,
            datePreset: datePreset.rawValue,
            integrationTime: integrationTime,
            timeSpan: timeSpan,
            spectralCoverage: spectralCoverage,
            spectralSampling: spectralSampling,
            resolvingPower: resolvingPower,
            bandpassWidth: bandpassWidth,
            restFrameEnergy: restFrameEnergy,
            selectedBands: selectedBands,
            selectedCollections: selectedCollections,
            selectedInstruments: selectedInstruments,
            selectedFilters: selectedFilters,
            selectedCalLevels: selectedCalLevels,
            selectedDataTypes: selectedDataTypes,
            selectedObsTypes: selectedObsTypes
        )
    }

    func loadFromSnapshot(_ snapshot: SearchFormSnapshot) {
        observationID = snapshot.observationID
        piName = snapshot.piName
        proposalID = snapshot.proposalID
        proposalTitle = snapshot.proposalTitle
        proposalKeywords = snapshot.proposalKeywords
        dataRelease = snapshot.dataRelease
        publicOnly = snapshot.publicOnly
        intent = IntentValue(rawValue: snapshot.intent) ?? .any
        target = snapshot.target
        resolver = ResolverValue(rawValue: snapshot.resolver) ?? .all
        pixelScale = snapshot.pixelScale
        observationDate = snapshot.observationDate
        datePreset = DatePresetValue(rawValue: snapshot.datePreset) ?? .none
        integrationTime = snapshot.integrationTime
        timeSpan = snapshot.timeSpan
        spectralCoverage = snapshot.spectralCoverage
        spectralSampling = snapshot.spectralSampling
        resolvingPower = snapshot.resolvingPower
        bandpassWidth = snapshot.bandpassWidth
        restFrameEnergy = snapshot.restFrameEnergy
        selectedBands = snapshot.selectedBands
        selectedCollections = snapshot.selectedCollections
        selectedInstruments = snapshot.selectedInstruments
        selectedFilters = snapshot.selectedFilters
        selectedCalLevels = snapshot.selectedCalLevels
        selectedDataTypes = snapshot.selectedDataTypes
        selectedObsTypes = snapshot.selectedObsTypes
    }
}
