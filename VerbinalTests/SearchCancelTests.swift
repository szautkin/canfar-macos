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
