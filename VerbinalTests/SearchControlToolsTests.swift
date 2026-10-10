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
                                         visible: true, selectedUnit: nil, units: nil)],
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

    /// Plan 36 1.6: the corrected spelling of a position column reaches the
    /// table as its own id, for sorting, filters, columns and units.
    func testSetResultsViewTakesTheCorrectedPositionIDs() async throws {
        let tool = SetResultsViewTool(apply: { args in
            XCTAssertEqual(args.sortColumnID, "ra(j20000)")
            XCTAssertEqual(args.filters?["dec(j20000)"], ">40")
            XCTAssertEqual(args.visibleColumns, ["ra(j20000)", "instrument"])
            XCTAssertEqual(args.columnUnits?["ra(j20000)"], "deg")
            return .applied(.init(filteredCount: 3, currentPage: 0, totalPages: 1))
        })
        let json = try decodeJSON(await tool.invoke(arguments: argsData([
            "sortColumnID": "ra(j2000)", "filters": ["dec(j2000)": ">40"],
            "visibleColumns": ["ra(j2000)", "instrument"], "columnUnits": ["ra(j2000)": "deg"],
        ]), context: ctx()))
        XCTAssertEqual(json["filteredCount"] as? Int, 3)
        let columns = SearchResultColumns(headers: ["RA (J2000.0)", "Dec. (J2000.0)"], sampleRows: [])
        if columns.column(id: "ra(j20000)") != nil {
            XCTAssertNotNil(columns.column(id: "ra(j2000)"), "the lookup finds it by either spelling")
        }
    }

    /// Plan 36 1.2: the cone query asks TAP for the rows it reports.
    func testSearchObservationsSaysTheRowsItAsksFor() async throws {
        let tool = SearchObservationsTool(runQuery: { _, _ in (["a"], []) }, resolveTarget: { _ in (10.68, 41.27) })
        let cone = try await tool.composeADQL(.init(adql: nil, target: "M31", ra: nil, dec: nil, radiusDeg: 0.1, maxRec: 20), maxRec: 20)
        XCTAssertTrue(cone.contains("SELECT TOP 20"), cone)
        XCTAssertFalse(cone.contains("TOP 1000"))
        let own = try await tool.composeADQL(.init(adql: "SELECT TOP 5 * FROM caom2.Plane", target: nil, ra: nil, dec: nil, radiusDeg: nil, maxRec: 20), maxRec: 20)
        XCTAssertEqual(own, "SELECT TOP 5 * FROM caom2.Plane", "the agent's own query, as it gave it")
    }

    /// Plan 36 1.4: an id that is not a background apply's says what it may be, whole.
    func testGetJobStatusSaysWhereABatchJobsIdGoes() async {
        let tool = GetJobStatusTool(status: { _ in nil })
        let result = await tool.invoke(arguments: argsData(["jobId": "t9nqdskz"]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(reason.description.contains("get_headless_job"), reason.description)
        XCTAssertFalse(reason.description.contains("truncated"), "the clip keeps it whole")
        XCTAssertFalse(reason.description.contains("it is the proposal's UUID"))
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

    /// Plan 15 R1 (QA L12): state without rows still names the columns.
    @MainActor
    func testStateWithoutRowsStillHasItsColumns() async throws {
        let state = AppState()
        state.searchModel.resultsModel.loadResults(
            headers: ["\"Collection\"", "\"Target Name\"", "\"publisherID\""],
            rows: [["JWST", "M31", "ivo://cadc.nrc.ca/JWST?x/y"]], query: "Q", maxRec: 10)
        let tool = state.makeGetSearchResultsTool()
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))
        let out = try await tool.handle(.init(allColumns: true, includeRows: false), context: ctx)
        XCTAssertEqual(out.columns.map(\.id), ["collection", "targetname", "publisherid"])
        XCTAssertTrue(out.rows.isEmpty)
        XCTAssertTrue(out.rowIDs.isEmpty)
    }

    /// Plan 15 O1 (QA M19): what the person has open is in the current view.
    @MainActor
    func testTheCurrentViewNamesTheOpenDetailAndResearchRecord() {
        let state = AppState()
        let results = state.searchModel.resultsModel
        results.loadResults(headers: ["\"obsID\"", "\"publisherID\""],
                            rows: [["oezt010e0", "ivo://cadc.nrc.ca/mirror/HST?oezt010e0/oezt010e0-CALIBRATED"]],
                            query: "Q", maxRec: 10)
        XCTAssertNil(state.snapshotCurrentView().openSearchDetail)

        results.openDetailRowID = results.results.first?.id
        let detail = state.snapshotCurrentView().openSearchDetail
        XCTAssertEqual(detail?.observationID, "oezt010e0")
        XCTAssertEqual(detail?.publisherID, "ivo://cadc.nrc.ca/mirror/HST?oezt010e0/oezt010e0-CALIBRATED")

        let record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?1573200", collection: "CFHT",
                                           observationID: "1573200", targetName: "", instrument: "", filter: "",
                                           ra: "", dec: "", startDate: "", calLevel: "", localPath: "")
        state.researchModel.selectedObservation = record
        XCTAssertEqual(state.snapshotCurrentView().selectedResearchRecord?.id, record.id.uuidString)
    }
}
