// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 30 R: a Radius field, as the Windows app has, and a search an
/// assistant can start without waiting — so cancel_search has one to stop.
@MainActor
final class SearchRadiusTests: XCTestCase {

    private func params(_ target: String, radius: String = "") -> SpatialBuilder.Params {
        SpatialBuilder.Params(target: target, resolver: .all, resolverCoords: ("210.802429", "54.34875"), pixelScale: "",
                              searchRadius: radius)
    }

    func testTheRadiusFieldSetsTheCone() {
        XCTAssertEqual(SpatialBuilder.circle(params("M101"))?.radius ?? 0, 1.0 / 60, accuracy: 1e-12, "1′ when empty")
        XCTAssertEqual(SpatialBuilder.circle(params("M101", radius: "0.2"))?.radius ?? 0, 0.2, accuracy: 1e-12)
        XCTAssertEqual(SpatialBuilder.circle(params("M101 0.5deg", radius: "0.2"))?.radius ?? 0, 0.5, accuracy: 1e-12,
                       "a radius typed after the target takes precedence")
        XCTAssertEqual(SpatialBuilder.circle(params("210.8 54.35", radius: "5'"))?.radius ?? 0, 5.0 / 60, accuracy: 1e-12,
                       "a pasted position too")
        let adql = SpatialBuilder.buildWhere(params("M101", radius: "0.2")).joined()
        XCTAssertTrue(adql.contains("CIRCLE('ICRS', 210.802429, 54.34875, 0.2)"), adql)
    }

    func testWhatTheFieldTakes() {
        XCTAssertEqual(SpatialBuilder.radiusDegrees("0.2"), 0.2)
        XCTAssertEqual(SpatialBuilder.radiusDegrees("30 arcsec") ?? 0, 30.0 / 3600, accuracy: 1e-12)
        XCTAssertEqual(SpatialBuilder.radiusDegrees("5'") ?? 0, 5.0 / 60, accuracy: 1e-12)
        XCTAssertNil(SpatialBuilder.radiusDegrees(""))
        XCTAssertNil(SpatialBuilder.radiusDegrees("wide"))
        XCTAssertNil(SpatialBuilder.radiusDegrees("0"))
    }

    /// A search saved before the field still loads; one saved with it keeps it.
    func testSavedSearchesKeepTheRadius() throws {
        let state = SearchFormState()
        state.target = "M101"
        state.searchRadius = "0.2"
        let restored = try JSONDecoder().decode(SearchFormSnapshot.self, from: JSONEncoder().encode(state.toSnapshot()))
        let back = SearchFormState()
        back.loadFromSnapshot(restored)
        XCTAssertEqual(back.searchRadius, "0.2")

        let before = try JSONEncoder().encode(SearchFormSnapshot(target: "M31"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        json.removeValue(forKey: "searchRadius")
        let old = try JSONDecoder().decode(SearchFormSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.target, "M31")
        XCTAssertNil(old.searchRadius)
    }

    func testTheToolsTakeTheRadiusAndTheWait() async throws {
        let state = AppState()
        let tools = state.makeAgentTools()
        let context = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        let set = try XCTUnwrap(tools.first { $0.definition.name == "set_search_form" })
        _ = await set.invoke(arguments: Data(#"{"target":"M101","searchRadius":0.2}"#.utf8), context: context)
        XCTAssertEqual(state.searchModel.formState.searchRadius, "0.2")
        let get = try XCTUnwrap(tools.first { $0.definition.name == "get_search_form" })
        guard case .data(let body) = await get.invoke(arguments: Data("{}".utf8), context: context) else { return XCTFail() }
        let form = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(form["searchRadius"] as? Double, 0.2)

        for name in ["set_search_form", "set_adql_editor"] {
            let schema = "\(try XCTUnwrap(tools.first { $0.definition.name == name }).definition.inputSchema)"
            XCTAssertTrue(schema.contains("wait"), name)
        }
        var started = SetSearchFormTool.Outcome()
        started.started = true
        let said = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SetSearchFormTool.Output(started))) as? [String: Any]
        XCTAssertEqual(said?["started"] as? Bool, true)
    }
}
