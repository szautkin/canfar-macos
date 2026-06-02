// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class SearchFormSnapshotTests: XCTestCase {

    // MARK: - Round-Trip

    /// Round-trips a *fully*-populated form through
    /// toSnapshot() → JSON → loadFromSnapshot() → toSnapshot() and asserts
    /// the before/after snapshots are equal. Because SearchFormSnapshot is
    /// Equatable and toSnapshot() reads every persisted field, this locks in
    /// that the snapshot covers 100% of the form state that survives a
    /// recent-search / saved-query round-trip (no field silently dropped).
    func testFullyPopulatedSnapshotRoundTripIsLossless() {
        let state = SearchFormState()
        state.observationID = "obs123"
        state.piName = "Jane Doe"
        state.proposalID = "prop1"
        state.proposalTitle = "Deep Field Survey"
        state.proposalKeywords = "galaxies, redshift"
        state.dataRelease = "2024"
        state.publicOnly = true
        state.intent = .calibration
        state.target = "M31"
        state.resolver = .ned
        state.pixelScale = "0.05"
        state.observationDate = "2020..2021"
        state.datePreset = .pastMonth
        state.integrationTime = "100"
        state.timeSpan = "1d"
        state.spectralCoverage = "400..700nm"
        state.spectralSampling = "> 1nm"
        state.resolvingPower = "5000"
        state.bandpassWidth = "100nm"
        state.restFrameEnergy = "5keV"
        state.selectedBands = ["Optical", "Infrared"]
        state.selectedCollections = ["JWST", "HST"]
        state.selectedInstruments = ["WFC3"]
        state.selectedFilters = ["F160W", "F125W"]
        state.selectedCalLevels = ["2", "3"]
        state.selectedDataTypes = ["image"]
        state.selectedObsTypes = ["OBJECT"]

        let original = state.toSnapshot()

        // Persist + reload through JSON, simulating recent-search storage.
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(SearchFormSnapshot.self, from: data)

        let restored = SearchFormState()
        restored.loadFromSnapshot(decoded)
        let roundTripped = restored.toSnapshot()

        XCTAssertEqual(roundTripped, original,
                       "Every persisted form field must survive the round-trip.")

        // Spot-check the typed fields on the restored state directly too,
        // since enum fields go through rawValue and back.
        XCTAssertEqual(restored.intent, .calibration)
        XCTAssertEqual(restored.resolver, .ned)
        XCTAssertEqual(restored.datePreset, .pastMonth)
        XCTAssertEqual(restored.selectedCollections, ["JWST", "HST"])
    }

    func testSnapshotRoundTrip() {
        let state = SearchFormState()
        state.target = "M31"
        state.selectedCollections = ["JWST"]
        state.observationDate = "2020..2021"
        state.intent = .science
        state.publicOnly = true
        state.resolver = .simbad
        state.piName = "Smith"

        let snapshot = state.toSnapshot()

        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try! encoder.encode(snapshot)

        // Decode from JSON
        let decoder = JSONDecoder()
        let decoded = try! decoder.decode(SearchFormSnapshot.self, from: data)

        // Load into new state
        let newState = SearchFormState()
        newState.loadFromSnapshot(decoded)

        XCTAssertEqual(newState.target, "M31")
        XCTAssertEqual(newState.selectedCollections, ["JWST"])
        XCTAssertEqual(newState.observationDate, "2020..2021")
        XCTAssertEqual(newState.intent, .science)
        XCTAssertTrue(newState.publicOnly)
        XCTAssertEqual(newState.resolver, .simbad)
        XCTAssertEqual(newState.piName, "Smith")
    }

    func testSnapshotDefaultsAreEmpty() {
        let snapshot = SearchFormSnapshot()

        XCTAssertEqual(snapshot.observationID, "")
        XCTAssertEqual(snapshot.piName, "")
        XCTAssertEqual(snapshot.target, "")
        XCTAssertEqual(snapshot.selectedBands, [])
        XCTAssertEqual(snapshot.selectedCollections, [])
        XCTAssertFalse(snapshot.publicOnly)
        XCTAssertEqual(snapshot.intent, "")
    }

    func testSnapshotEncodesAllFields() {
        let state = SearchFormState()
        state.observationID = "obs123"
        state.piName = "PI"
        state.proposalID = "prop1"
        state.proposalTitle = "Title"
        state.proposalKeywords = "key1"
        state.dataRelease = "2020"
        state.target = "M51"
        state.pixelScale = "0.5"
        state.integrationTime = "100"
        state.timeSpan = "1d"
        state.spectralCoverage = "400..700nm"
        state.spectralSampling = "> 1nm"
        state.resolvingPower = "5000"
        state.bandpassWidth = "100nm"
        state.restFrameEnergy = "5keV"
        state.selectedBands = ["Optical"]
        state.selectedInstruments = ["WFC3"]
        state.selectedFilters = ["F160W"]
        state.selectedCalLevels = ["2"]
        state.selectedDataTypes = ["image"]
        state.selectedObsTypes = ["OBJECT"]

        let snapshot = state.toSnapshot()
        let data = try! JSONEncoder().encode(snapshot)
        let decoded = try! JSONDecoder().decode(SearchFormSnapshot.self, from: data)

        XCTAssertEqual(decoded.observationID, "obs123")
        XCTAssertEqual(decoded.piName, "PI")
        XCTAssertEqual(decoded.proposalID, "prop1")
        XCTAssertEqual(decoded.proposalTitle, "Title")
        XCTAssertEqual(decoded.proposalKeywords, "key1")
        XCTAssertEqual(decoded.dataRelease, "2020")
        XCTAssertEqual(decoded.target, "M51")
        XCTAssertEqual(decoded.pixelScale, "0.5")
        XCTAssertEqual(decoded.integrationTime, "100")
        XCTAssertEqual(decoded.timeSpan, "1d")
        XCTAssertEqual(decoded.spectralCoverage, "400..700nm")
        XCTAssertEqual(decoded.spectralSampling, "> 1nm")
        XCTAssertEqual(decoded.resolvingPower, "5000")
        XCTAssertEqual(decoded.bandpassWidth, "100nm")
        XCTAssertEqual(decoded.restFrameEnergy, "5keV")
        XCTAssertEqual(decoded.selectedBands, ["Optical"])
        XCTAssertEqual(decoded.selectedInstruments, ["WFC3"])
        XCTAssertEqual(decoded.selectedFilters, ["F160W"])
        XCTAssertEqual(decoded.selectedCalLevels, ["2"])
        XCTAssertEqual(decoded.selectedDataTypes, ["image"])
        XCTAssertEqual(decoded.selectedObsTypes, ["OBJECT"])
    }

    // MARK: - Auto-Naming

    func testAutoNameWithCollection() {
        var snapshot = SearchFormSnapshot()
        snapshot.selectedCollections = ["JWST"]
        let name = snapshot.autoName()
        XCTAssertTrue(name.hasPrefix("JWST"), "Name should start with collection, got: \(name)")
    }

    func testAutoNameWithTarget() {
        var snapshot = SearchFormSnapshot()
        snapshot.target = "M31"
        let name = snapshot.autoName()
        XCTAssertTrue(name.hasPrefix("M31"), "Name should start with target, got: \(name)")
    }

    func testAutoNameWithoutCollection() {
        let snapshot = SearchFormSnapshot()
        let name = snapshot.autoName()
        // Localized — assert structural invariant (non-empty + contains em-dash
        // separator between fallback label and timestamp) rather than English
        // prefix. The same call on an fr-locale machine returns "Recherche — …".
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.contains("\u{2014}"), "Name should contain em-dash, got: \(name)")
    }

    func testAutoNameContainsTimestamp() {
        let snapshot = SearchFormSnapshot()
        let name = snapshot.autoName()
        // Should contain a year like "2026". Matches both "Aug 17, 2026" (en)
        // and "17 août 2026" (fr) date styles.
        let yearStr = String(Calendar.current.component(.year, from: Date()))
        XCTAssertTrue(name.contains(yearStr), "Name should contain current year, got: \(name)")
    }

    // MARK: - Filter Summary

    // Assertions below check that user data (M31, JWST) appears in the
    // localized summary, not that the summary matches a specific English
    // phrasing. filterSummary() now routes each fragment through
    // String(localized:) so "Target: M31" appears as "Cible : M31" in fr.

    func testFilterSummaryWithTarget() {
        var snapshot = SearchFormSnapshot()
        snapshot.target = "M31"
        let summary = snapshot.filterSummary()
        XCTAssertTrue(summary.contains("M31"), "Summary should include target value, got: \(summary)")
    }

    func testFilterSummaryMultipleFields() {
        var snapshot = SearchFormSnapshot()
        snapshot.target = "M31"
        snapshot.selectedCollections = ["JWST"]
        let summary = snapshot.filterSummary()
        XCTAssertTrue(summary.contains("M31"), "Summary should include target, got: \(summary)")
        XCTAssertTrue(summary.contains("JWST"), "Summary should include collection, got: \(summary)")
        XCTAssertTrue(summary.contains(" | "), "Summary should join fragments with ' | ', got: \(summary)")
    }

    func testFilterSummaryEmpty() {
        let snapshot = SearchFormSnapshot()
        // "No filters" in en, "Aucun filtre" in fr — both non-empty.
        XCTAssertFalse(snapshot.filterSummary().isEmpty)
    }
}
