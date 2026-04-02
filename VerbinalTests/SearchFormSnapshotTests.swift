// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class SearchFormSnapshotTests: XCTestCase {

    // MARK: - Round-Trip

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
        XCTAssertTrue(name.hasPrefix("Search"), "Name should start with 'Search', got: \(name)")
    }

    func testAutoNameContainsTimestamp() {
        let snapshot = SearchFormSnapshot()
        let name = snapshot.autoName()
        // Should contain a year like "2026"
        let yearStr = String(Calendar.current.component(.year, from: Date()))
        XCTAssertTrue(name.contains(yearStr), "Name should contain current year, got: \(name)")
    }

    // MARK: - Filter Summary

    func testFilterSummaryWithTarget() {
        var snapshot = SearchFormSnapshot()
        snapshot.target = "M31"
        let summary = snapshot.filterSummary()
        XCTAssertEqual(summary, "Target: M31")
    }

    func testFilterSummaryMultipleFields() {
        var snapshot = SearchFormSnapshot()
        snapshot.target = "M31"
        snapshot.selectedCollections = ["JWST"]
        let summary = snapshot.filterSummary()
        XCTAssertTrue(summary.contains("Target: M31"))
        XCTAssertTrue(summary.contains("Collection: JWST"))
        XCTAssertTrue(summary.contains(" | "))
    }

    func testFilterSummaryEmpty() {
        let snapshot = SearchFormSnapshot()
        XCTAssertEqual(snapshot.filterSummary(), "No filters")
    }
}
