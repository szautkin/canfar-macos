// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Cancel beside the search spinner (Windows 1.4.1 parity): the search
/// stops, the rows already shown stay, and it is not kept as a recent one.
@MainActor
final class SearchCancelTests: XCTestCase {

    private let csv = "observationID,collection\nobs-1,JWST\nobs-2,HST\n"
    /// Holds the next TAP request open until the test releases it.
    private let release = DispatchSemaphore(value: 0)
    private var holdRequests = false

    override func tearDown() {
        release.signal()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeModel() -> SearchFormModel {
        let body = Data(csv.utf8)
        let release = release
        let hold = { [unowned self] in self.holdRequests }
        MockURLProtocol.requestHandler = { request in
            if hold() { _ = release.wait(timeout: .now() + 5) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        return SearchFormModel(
            tapClient: TAPClient(session: MockURLProtocol.mockSession()),
            recentSearchStore: RecentSearchStore(fileName: "test-recent-\(UUID().uuidString).json"),
            savedQueryStore: SavedQueryStore(fileName: "test-saved-\(UUID().uuidString).json"))
    }

    private func waitUntilSearching(_ model: SearchFormModel) async {
        for _ in 0..<200 where !model.isSearching { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Plan 15 R2 (QA L13): what the checker is sure is wrong is not sent,
    /// whoever runs it.
    func testAQueryTheCheckerRefusesIsNotSent() async {
        let model = makeModel()
        final class Sent: @unchecked Sendable { var count = 0 }
        let sent = Sent()
        MockURLProtocol.requestHandler = { request in
            sent.count += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let outcome = await model.executeRawQuery("SELECT * FROM caom2.Plane LIMIT 5", fromEditor: true)
        guard case .refused(let message) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertTrue(message.contains("SELECT TOP 5"), message)
        let report = AppState.report(outcome)
        XCTAssertFalse(report.executed, "a refused query was not executed (plan 17 G9)")
        XCTAssertEqual(report.searchError, message)
        XCTAssertEqual(sent.count, 0, "nothing went to the server")
        XCTAssertNotNil(model.searchError)
        XCTAssertTrue(model.recentSearchStore.searches.isEmpty)
    }

    func testACompletedSearchReportsItsRowsAndIsKeptAsRecent() async {
        let model = makeModel()
        model.formState.observationID = "obs"
        let outcome = await model.executeSearch()
        XCTAssertEqual(outcome, .completed(rows: 2))
        XCTAssertEqual(model.resultsModel.totalRows, 2)
        XCTAssertEqual(model.recentSearchStore.searches.count, 1)
        XCTAssertFalse(model.isSearching)
    }

    func testCancelStopsTheSearchKeepsTheRowsShownAndSavesNoRecent() async {
        let model = makeModel()
        model.formState.observationID = "obs"
        await model.executeSearch()
        let recents = model.recentSearchStore.searches.count

        holdRequests = true
        model.formState.observationID = "other"
        let running = Task { await model.executeSearch() }
        await waitUntilSearching(model)
        XCTAssertTrue(model.isSearching)
        model.cancelSearch()
        release.signal()
        let outcome = await running.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.searchError, "a cancel is not an error")
        XCTAssertEqual(model.resultsModel.totalRows, 2, "the rows already shown stay")
        XCTAssertEqual(model.recentSearchStore.searches.count, recents, "a cancelled search is not kept")
    }

    func testTheADQLEditorCancelsTheSameWay() async {
        let model = makeModel()
        holdRequests = true
        let running = Task { await model.executeRawQuery("SELECT TOP 1 * FROM caom2.Observation") }
        await waitUntilSearching(model)
        model.cancelSearch()
        release.signal()
        let outcome = await running.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(model.isSearching)
    }

    func testANewerSearchSupersedesARunningOne() async {
        let model = makeModel()
        holdRequests = true
        let first = Task { await model.executeRawQuery("SELECT 1") }
        await waitUntilSearching(model)
        holdRequests = false
        let newer = Task { await model.executeRawQuery("SELECT 2") }
        // The newer search cancels the first as it starts; then free the
        // loader thread the first request's handler is holding.
        try? await Task.sleep(for: .milliseconds(50))
        release.signal()
        let second = await newer.value
        let superseded = await first.value
        XCTAssertEqual(second, .completed(rows: 2))
        XCTAssertEqual(superseded, .cancelled)
        XCTAssertFalse(model.isSearching, "the newer search owned the spinner and finished")
    }

    func testCancelWithNothingRunningIsHarmless() {
        let model = makeModel()
        model.cancelSearch()
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.searchError)
    }

    // MARK: - Agent tools

    func testSearchToolRepliesSayWhenThePersonCancelled() throws {
        var outcome = SetSearchFormTool.Outcome()
        outcome.executed = true
        outcome.cancelled = true
        let form = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SetSearchFormTool.Output(outcome))) as? [String: Any]
        XCTAssertEqual(form?["cancelled"] as? Bool, true)
        let editor = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SetADQLEditorTool.Output(.init(adql: "SELECT 1", executed: true, cancelled: true)))) as? [String: Any]
        XCTAssertEqual(editor?["cancelled"] as? Bool, true)
    }

    func testCancelSearchToolReportsWhetherAnythingWasRunning() async throws {
        for running in [true, false] {
            let tool = CancelSearchTool(cancel: { running })
            let result = await tool.invoke(arguments: Data("{}".utf8), context: AIToolContext(
                origin: .external(clientID: "test"), proposals: InMemoryProposalStore(),
                budget: ProposalBudget(limit: 9)))
            guard case .data(let bytes) = result else { return XCTFail("expected data, got \(result)") }
            let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            XCTAssertEqual(body?["cancelled"] as? Bool, running)
        }
    }
}

/// Queries run from the ADQL editor are kept in Recent Searches and load
/// back into the editor (Windows 1.4.1 parity).
@MainActor
final class EditorRecentSearchTests: XCTestCase {

    private func makeModel() -> SearchFormModel {
        let body = Data("observationID\nobs-1\n".utf8)
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        return SearchFormModel(
            tapClient: TAPClient(session: MockURLProtocol.mockSession()),
            recentSearchStore: RecentSearchStore(fileName: "test-recent-\(UUID().uuidString).json"),
            savedQueryStore: SavedQueryStore(fileName: "test-saved-\(UUID().uuidString).json"))
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAnEditorQueryIsKeptAndLoadsBackIntoTheEditor() async throws {
        let model = makeModel()
        let adql = "SELECT TOP 5\n  observationID\nFROM caom2.Observation"
        await model.executeRawQuery(adql, fromEditor: true)
        let recent = try XCTUnwrap(model.recentSearchStore.searches.first)
        XCTAssertTrue(recent.isFromEditor)
        XCTAssertEqual(recent.name, "SELECT TOP 5 observationID FROM caom2.Observation", "named by the query, on one line")

        model.resultsModel.adqlQuery = ""
        model.selectedTab = .search
        model.load(recent)
        XCTAssertEqual(model.selectedTab, .adql)
        XCTAssertEqual(model.resultsModel.adqlQuery, adql)
    }

    func testASavedQueryRunFromItsListIsNotKeptAsRecent() async {
        let model = makeModel()
        await model.executeRawQuery("SELECT TOP 1 * FROM caom2.Plane")
        XCTAssertTrue(model.recentSearchStore.searches.isEmpty)
    }

    func testOlderRecentSearchesWithoutAQueryStillDecode() throws {
        let current = RecentSearch(name: "M31", formSnapshot: SearchFormSnapshot(), adql: "SELECT 1")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["adql"] = nil
        let older = try JSONDecoder().decode(RecentSearch.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.name, "M31")
        XCTAssertNil(older.adql)
        XCTAssertFalse(older.isFromEditor)
    }

    func testLongQueriesAreShortenedForTheirName() {
        let name = RecentSearch.name(forQuery: String(repeating: "x ", count: 100), limit: 20)
        XCTAssertEqual(name.count, 20)
        XCTAssertTrue(name.hasSuffix("…"))
    }
}
