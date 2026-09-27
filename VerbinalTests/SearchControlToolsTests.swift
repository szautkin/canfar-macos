// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Unit coverage for the Search-parity tool batch (form control, data
/// train, ADQL editor, results-table control, recent-search writes).
/// Stub closures — no network, no live view models.
final class SearchControlToolsTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    private func argsData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func decodeJSON(_ result: ToolResult) throws -> [String: Any] {
        guard case .data(let data) = result else {
            XCTFail("expected .data, got \(result)")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - set_search_form

    func testSetSearchFormForwardsFieldsAndReportsExecution() async throws {
        let tool = SetSearchFormTool(apply: { args in
            XCTAssertEqual(args.piName, "Hubble")
            XCTAssertEqual(args.collections, ["CFHT"])
            XCTAssertEqual(args.execute, true)
            return .init(executed: true, resultCount: 42, searchError: nil)
        })
        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["piName": "Hubble", "collections": ["CFHT"], "execute": true]),
            context: ctx()))
        XCTAssertEqual(json["applied"] as? Bool, true)
        XCTAssertEqual(json["executed"] as? Bool, true)
        XCTAssertEqual(json["resultCount"] as? Int, 42)
    }

    func testSetSearchFormSurfacesApplyError() async {
        let tool = SetSearchFormTool(apply: { _ in .init(error: "Unknown intent 'bogus'") })
        let result = await tool.invoke(arguments: argsData(["intent": "bogus"]), context: ctx())
        guard case .failed(let reason) = result, case .invalidArgument(let msg) = reason else {
            return XCTFail("expected invalidArgument, got \(result)")
        }
        XCTAssertTrue(msg.contains("intent"))
    }

    // MARK: - set_adql_editor

    func testSetADQLEditorRejectsConflictingAndEmptyRequests() async {
        let tool = SetADQLEditorTool(apply: { _ in .init() })
        let both = await tool.invoke(
            arguments: argsData(["adql": "SELECT 1", "generateFromForm": true]), context: ctx())
        guard case .failed = both else { return XCTFail("expected .failed for both sources") }
        let nothing = await tool.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed = nothing else { return XCTFail("expected .failed for no-op call") }
    }

    func testSetADQLEditorEchoesFinalTextAndExecution() async throws {
        let tool = SetADQLEditorTool(apply: { args in
            XCTAssertEqual(args.adql, "SELECT TOP 5 * FROM caom2.Plane")
            return .init(adql: args.adql ?? "", executed: true, resultCount: 5, searchError: nil)
        })
        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["adql": "SELECT TOP 5 * FROM caom2.Plane", "execute": true]),
            context: ctx()))
        XCTAssertEqual(json["executed"] as? Bool, true)
        XCTAssertEqual(json["resultCount"] as? Int, 5)
        XCTAssertEqual(json["adql"] as? String, "SELECT TOP 5 * FROM caom2.Plane")
    }

    // MARK: - select_search_tab

    func testSelectSearchTabForwardsAndRejects() async throws {
        let ok = SelectSearchTabTool(select: { tab in
            XCTAssertEqual(tab, "results"); return nil
        })
        let json = try decodeJSON(await ok.invoke(
            arguments: argsData(["tab": "results"]), context: ctx()))
        XCTAssertEqual(json["applied"] as? Bool, true)

        let failing = SelectSearchTabTool(select: { _ in "Unknown tab 'bogus'" })
        let bad = await failing.invoke(arguments: argsData(["tab": "bogus"]), context: ctx())
        guard case .failed = bad else { return XCTFail("expected .failed, got \(bad)") }
    }

    // MARK: - quick_search

    func testQuickSearchForwardsColumnAndValue() async throws {
        let tool = QuickSearchTool(run: { columnID, value in
            XCTAssertEqual(columnID, "collection")
            XCTAssertEqual(value, "JWST")
            return .init(resultCount: 7, searchError: nil)
        })
        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["columnID": "collection", "value": "JWST"]), context: ctx()))
        XCTAssertEqual(json["resultCount"] as? Int, 7)
    }

    // MARK: - get_search_results

    func testGetSearchResultsPassesArgsThrough() async throws {
        let tool = GetSearchResultsTool(snapshot: { args in
            XCTAssertEqual(args.page, 3)
            XCTAssertEqual(args.allColumns, true)
            return .init(hasResults: true, adqlQuery: "SELECT 1", totalRows: 500,
                         filteredCount: 120, maxRecordReached: false, currentPage: 0,
                         totalPages: 5, rowsPerPage: 100, sortColumnID: "obsid",
                         sortAscending: false, activeFilters: ["collection": "CFHT"],
                         columns: [.init(id: "obsid", label: "Obs. ID", kind: "text",
                                         visible: true, selectedUnit: nil)],
                         returnedPage: 3, rowIDs: ["a"], rows: [["x"]],
                         rowsTruncated: false)
        })
        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["page": 3, "allColumns": true]), context: ctx()))
        XCTAssertEqual(json["filteredCount"] as? Int, 120)
        XCTAssertEqual(json["returnedPage"] as? Int, 3)
        let filters = try XCTUnwrap(json["activeFilters"] as? [String: String])
        XCTAssertEqual(filters["collection"], "CFHT")
    }

    // MARK: - set_results_view

    func testSetResultsViewMapsAppliedAndRejected() async throws {
        let ok = SetResultsViewTool(apply: { args in
            XCTAssertEqual(args.sortColumnID, "instrument")
            XCTAssertEqual(args.filters?["piname"], "smith")
            return .applied(.init(filteredCount: 12, currentPage: 0, totalPages: 1))
        })
        let json = try decodeJSON(await ok.invoke(
            arguments: argsData(["sortColumnID": "instrument", "filters": ["piname": "smith"]]),
            context: ctx()))
        XCTAssertEqual(json["filteredCount"] as? Int, 12)

        let rejected = SetResultsViewTool(apply: { _ in .rejected("Unknown column 'bogus'") })
        let bad = await rejected.invoke(
            arguments: argsData(["sortColumnID": "bogus"]), context: ctx())
        guard case .failed(let reason) = bad, case .invalidArgument = reason else {
            return XCTFail("expected invalidArgument, got \(bad)")
        }
    }

    // MARK: - open_observation_detail

    func testOpenObservationDetailReportsUnknownRow() async {
        let tool = ObservationDetailActions.openByRowID { _ in "No results row with id 'nope'" }
        let result = await tool.invoke(arguments: argsData(["rowID": "nope"]), context: ctx())
        guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
    }

    // MARK: - recent-search writes

    func testRenameRecentSearchPlanValidates() async throws {
        let tool = RenameRecentSearchTool()
        do {
            _ = try await tool.plan(.init(id: "not-a-uuid", name: "x"), context: ctx())
            XCTFail("expected invalidArgument for bad id")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        }
        do {
            _ = try await tool.plan(.init(id: UUID().uuidString, name: "   "), context: ctx())
            XCTFail("expected invalidArgument for empty name")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        }
        let plan = try await tool.plan(
            .init(id: UUID().uuidString, name: "  M31 sweep  "), context: ctx())
        XCTAssertEqual(plan.kind, "rename_recent_search")
        let payload = try JSONDecoder().decode(RenameRecentSearchTool.Payload.self, from: plan.payload)
        XCTAssertEqual(payload.name, "M31 sweep")
    }

    func testRemoveRecentSearchPlanRejectsNonUUID() async {
        do {
            _ = try await RemoveRecentSearchTool().plan(.init(id: "42"), context: ctx())
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }
    }

    @MainActor
    func testRecentSearchAppliersMutateStore() async throws {
        let store = RecentSearchStore(fileName: "test-recent-\(UUID().uuidString).json")
        let activity = AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json")
        let search = RecentSearch(name: "before", formSnapshot: SearchFormSnapshot())
        store.save(search)
        let saved = try XCTUnwrap(store.searches.first)

        let renamePlan = try await RenameRecentSearchTool().plan(
            .init(id: saved.id.uuidString, name: "after"), context: ctx())
        try await RenameRecentSearchApplier(store: store, activity: activity).apply(
            PendingProposal(toolName: "rename_recent_search", kind: renamePlan.kind,
                            summary: renamePlan.summary, payload: renamePlan.payload,
                            origin: .external(clientID: "test"), requestID: UUID()))
        XCTAssertEqual(store.searches.first?.name, "after")

        let clearPlan = try await ClearRecentSearchesTool().plan(EmptyArgs(), context: ctx())
        try await ClearRecentSearchesApplier(store: store, activity: activity).apply(
            PendingProposal(toolName: "clear_recent_searches", kind: clearPlan.kind,
                            summary: clearPlan.summary, payload: clearPlan.payload,
                            origin: .external(clientID: "test"), requestID: UUID()))
        XCTAssertTrue(store.searches.isEmpty)
    }
}
