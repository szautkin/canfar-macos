// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
import MCPCore
@testable import Verbinal

/// Plan 30 S: a tool says the shape of what it takes, refuses what it
/// does not, and never reports done a change that changed nothing.
@MainActor
final class ToolShapesTests: XCTestCase {

    private func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let object)? = value { return object }
        return nil
    }

    private func tool(_ name: String) throws -> any AITool {
        try XCTUnwrap(AppState().makeAgentTools().first { $0.definition.name == name })
    }

    /// The QA pass: a rating sent as text was refused, and the fields nested
    /// under a key the item does not take were accepted and wrote nothing.
    func testABulkNotesItemIsTheSingleNotesShape() throws {
        let bulk = try tool("bulk_update_observation_notes").definition.inputSchema
        let single = try tool("update_observation_note").definition.inputSchema
        XCTAssertEqual(object(object(object(bulk)?["properties"])?["items"])?["items"], single)

        let nested = ToolInputSchema.check(schema: bulk, arguments: Data(#"""
        {"items":[{"publisher_id":"a","notes":{"text":"x","rating":3}}]}
        """#.utf8))
        guard case .refused(let why) = nested else { return XCTFail("\(nested)") }
        XCTAssertTrue(why.contains("in `items[0]` [\"notes\"]"), why)
        guard case .accepted = ToolInputSchema.check(schema: bulk, arguments: Data(#"{"items":[{"publisher_id":"a","rating":3}]}"#.utf8)) else {
            return XCTFail("the documented shape is taken")
        }
    }

    func testANoteChangeThatChangesNothingIsRefused() {
        XCTAssertEqual(UpdateObservationNoteTool.refusal(.init(publisher_id: "a")),
                       "nothing to change for a: give text, rating or tags")
        XCTAssertEqual(UpdateObservationNoteTool.refusal(.init(publisher_id: "a", rating: 9)), "rating must be 0-5")
        XCTAssertNil(UpdateObservationNoteTool.refusal(.init(publisher_id: "a", tags: [])), "clearing the tags is a change")
    }

    func testTheCubeTransferTakesTheViewsCurve() throws {
        let transfer = try tool("set_cube_transfer").definition.inputSchema
        let view = try tool("set_cube_view").definition.inputSchema
        let curve = { (schema: JSONValue) in self.object(self.object(schema)?["properties"])?["opacityCurve"] }
        XCTAssertNotNil(object(curve(transfer))?["items"], "its items are described")
        XCTAssertEqual(curve(transfer), curve(view))
    }

    func testAWrongUnitNamesTheRightOnes() async throws {
        let context = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        let state = AppState()
        state.searchModel.resultsModel.loadResults(headers: ["RA (J2000.0)"], rows: [["10.5"]], query: "SELECT 1", maxRec: 10)
        let setView = try XCTUnwrap(state.makeAgentTools().first { $0.definition.name == "set_results_view" })
        let result = await setView.invoke(arguments: Data(#"{"columnUnits":{"ra(j20000)":"deg"}}"#.utf8), context: context)
        XCTAssertTrue("\(result)".contains("it takes hms, degrees"), "\(result)")

        // A column that is not there is said to be so, with the ones that have units (handout 31).
        let unknown = await setView.invoke(arguments: Data(#"{"columnUnits":{"ra":"degrees"}}"#.utf8), context: context)
        XCTAssertTrue("\(unknown)".contains("Unknown column 'ra'; the columns with units are ra(j20000)"), "\(unknown)")
    }

    /// Plan 30 N4: navigate_to says when the screen changed where no one
    /// can see it.
    func testNavigatingWithNoWindowShowingSaysSo() async throws {
        let context = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget())
        func answer(_ unseen: String?) async throws -> [String: Any] {
            let tool = NavigateToTool(navigate: { _ in unseen })
            guard case .data(let data) = await tool.invoke(arguments: Data(#"{"mode":"search"}"#.utf8), context: context) else {
                XCTFail("navigate_to failed")
                return [:]
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let unseen = try await answer(UISnapshot.notShowing)
        XCTAssertEqual(unseen["navigated"] as? Bool, true)
        XCTAssertEqual(unseen["showing"] as? Bool, false)
        XCTAssertEqual(unseen["note"] as? String, UISnapshot.notShowing)
        let seen = try await answer(nil)
        XCTAssertNil(seen["showing"], "absent while a window shows")
    }

    /// Plan 30 N5: an export of the table says it holds the columns shown.
    func testAnExportSaysItsRowsAndColumns() async throws {
        let applier = ExportSearchResultsApplier(
            run: { _, _, _ in SearchExport(path: "/Users/u/Downloads/results.csv", shape: SearchExport.shown(rows: 120, columns: 8)) },
            activity: AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let proposal = PendingProposal(toolName: "export_search_results", kind: "export_search_results", summary: "Export",
                                       payload: try JSONEncoder().encode(ExportSearchResultsTool.Payload(format: "csv", adql: nil, maxRecords: nil)),
                                       origin: .external(clientID: "t"))
        let extra = try JSONDecoder().decode(AutoAppliedAck.Extra.self, from: try await applier.applyReturningResult(proposal))
        XCTAssertEqual(extra.file, "/Users/u/Downloads/results.csv")
        XCTAssertTrue(extra.note?.hasPrefix("120 rows × 8 columns: the columns shown") == true, extra.note ?? "")
    }
}
