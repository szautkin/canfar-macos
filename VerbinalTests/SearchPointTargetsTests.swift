// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// An assistant can point at Search's form and its results, not only at
/// the tabs (plan 17 G9, QA M19).
@MainActor
final class SearchPointTargetsTests: XCTestCase {

    func testTheFormsSectionsCanBePointedAt() async throws {
        let state = AppState()
        state.currentMode = .search
        state.searchModel.selectedTab = .search
        let targets = try await HostedContentView.pointTargets(state, waitingFor: "search.target")
        for id in ["search.observation", "search.spatial", "search.target", "search.temporal", "search.spectral",
                   "search.dataTrain", "search.run"] {
            XCTAssertTrue(targets.contains(id), "\(id) in \(targets.sorted())")
        }
    }

    func testTheResultsControlsCanBePointedAt() async throws {
        let state = AppState()
        state.currentMode = .search
        // Columns shown by default, so the table has headers and filters to read.
        state.searchModel.resultsModel.loadResults(headers: ["Collection", "Target Name", "Instrument"],
                                                   rows: [["HST", "M31", "ACS/WFC"]],
                                                   query: "SELECT 1", maxRec: 10)
        state.searchModel.selectedTab = .results
        let targets = try await HostedContentView.pointTargets(state, waitingFor: "results.filters")
        for id in ["results.export", "results.columns", "results.rowsPerPage", "results.header", "results.filters"] {
            XCTAssertTrue(targets.contains(id), "\(id) in \(targets.sorted())")
        }
    }
}
