// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 54 B–E: results know their publisher ID whatever the query called
/// it, the editor runs a query with it, and the tools carry it per row.
@MainActor
final class PublisherIDResultsTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeModel(answering csv: String) -> SearchFormModel {
        let body = Data(csv.utf8)
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        return SearchFormModel(
            tapClient: TAPClient(session: MockURLProtocol.mockSession()),
            recentSearchStore: RecentSearchStore(fileName: "test-recent-\(UUID().uuidString).json"),
            savedQueryStore: SavedQueryStore(fileName: "test-saved-\(UUID().uuidString).json"))
    }

    private let context = AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(),
                                        budget: ProposalBudget(limit: 9))

    private func results(_ headers: [String], _ rows: [[String]]) -> SearchResultsModel {
        let model = SearchResultsModel()
        model.loadResults(headers: headers, rows: rows, query: "", maxRec: 100)
        return model
    }

    // MARK: - B. The editor runs it with its publisher ID (D1)

    func testTheEditorShowsTheQueryAsItRanAndKeepsItAsRecent() async {
        let model = makeModel(answering: "productID,Publisher ID\n1227446g,ivo://cadc.nrc.ca/CFHT?1227446/1227446g\n")
        let outcome = await model.executeRawQuery("SELECT TOP 1 p.productID FROM caom2.Plane AS p", fromEditor: true)
        XCTAssertEqual(outcome, .completed(rows: 1))
        let ran = "SELECT TOP 1 p.productID, p.publisherID AS \"Publisher ID\" FROM caom2.Plane AS p"
        XCTAssertEqual(model.resultsModel.adqlQuery, ran, "the editor's text is the query that ran")
        XCTAssertEqual(model.recentSearchStore.searches.first?.adql, ran)
        XCTAssertNil(model.resultsModel.identifierGap)
        let row = try? XCTUnwrap(model.resultsModel.results.first)
        XCTAssertEqual(row.map { model.resultsModel.columns.publisherID(in: $0) }, "ivo://cadc.nrc.ca/CFHT?1227446/1227446g")
    }

    func testAnObservationQuerySaysWhyItsRowsHaveNoPreviews() async {
        let model = makeModel(answering: "observationID,Observation URI\n1227446,caom:CFHT/1227446\n")
        await model.executeRawQuery("SELECT TOP 1 o.observationID FROM caom2.Observation AS o")
        XCTAssertEqual(model.resultsModel.identifierGap,
                       .observations(join: "JOIN caom2.Plane AS Plane ON Plane.obsID = o.obsID"))
        let row = model.resultsModel.results[0]
        XCTAssertEqual(model.resultsModel.columns.publisherID(in: row), "", "no product: no previews or downloads")
        XCTAssertEqual(model.resultsModel.columns.metadataID(in: row), "caom:CFHT/1227446", "details open by its URI")
        XCTAssertEqual(row.id, "caom:CFHT/1227446")
    }

    // MARK: - C. Found whatever the query called it

    func testObsCoresIdentifierGivesEachRowItsPublisherID() {
        let model = results(["obs_publisher_did", "target_name"], [["ivo://cadc.nrc.ca/HST?a/b", "M31"]])
        XCTAssertEqual(model.columns.identifier?.identifies, .product)
        XCTAssertEqual(model.results[0].id, "ivo://cadc.nrc.ca/HST?a/b")
        XCTAssertNotNil(model.result(publisherID: "ivo://cadc.nrc.ca/HST?a/b"))
    }

    func testAProductsIDWinsOverItsObservationsURI() {
        let model = results(["Preview", "Observation URI", "publisher_id"],
                            [["caom:CFHT/1", "caom:CFHT/1", "ivo://cadc.nrc.ca/CFHT?1/1g"]])
        XCTAssertEqual(model.columns.publisherID(in: model.results[0]), "ivo://cadc.nrc.ca/CFHT?1/1g")
        XCTAssertEqual(model.columns.metadataID(in: model.results[0]), "ivo://cadc.nrc.ca/CFHT?1/1g")
    }

    func testResultsWithoutAnIdentifierHaveNone() {
        let model = results(["collection", "obsid"], [["CFHT", "1227446"]])
        XCTAssertNil(model.columns.identifier)
        XCTAssertEqual(model.columns.publisherID(in: model.results[0]), "")
        XCTAssertEqual(model.results[0].id, "1227446", "the observation ID, as before")
    }

    // MARK: - D. The tools

    func testSearchObservationsAddsItAndCarriesItPerRow() async throws {
        final class Ran: @unchecked Sendable { var adql = "" }
        let ran = Ran()
        let tool = SearchObservationsTool(
            runQuery: { adql, _ in
                ran.adql = adql
                return (["productID", "Publisher ID"], [["1g", "ivo://cadc.nrc.ca/CFHT?1/1g"], ["1o", ""]])
            },
            resolveTarget: { _ in (0, 0) })
        let output = try await tool.handle(.init(adql: "SELECT TOP 2 Plane.productID FROM caom2.Plane AS Plane"),
                                           context: context)
        XCTAssertEqual(ran.adql, "SELECT TOP 2 Plane.productID, Plane.publisherID AS \"Publisher ID\" FROM caom2.Plane AS Plane")
        XCTAssertEqual(output.adqlExecuted, ran.adql)
        XCTAssertEqual(output.identifierColumn, "Publisher ID")
        XCTAssertEqual(output.publisherIDs, ["ivo://cadc.nrc.ca/CFHT?1/1g", nil])
        XCTAssertEqual(output.identifier.added, "Plane.publisherID AS \"Publisher ID\"")
        XCTAssertEqual(output.identifier.identifies, "product")
    }

    func testSearchObservationsSaysWhyASummaryHasNone() async throws {
        let tool = SearchObservationsTool(runQuery: { _, _ in (["n"], [["3"]]) }, resolveTarget: { _ in (0, 0) })
        let output = try await tool.handle(.init(adql: "SELECT COUNT(*) AS n FROM caom2.Plane"),
                                           context: context)
        XCTAssertEqual(output.publisherIDs, [nil])
        XCTAssertNil(output.identifier.added)
        XCTAssertEqual(output.identifier.note, ADQLIdentifier.Gap.summarized.message)
    }

    func testAProductIsNamedByItsPublisherIDOrByItsRow() async throws {
        let resolve: ProductReference.Resolve = { row, metadata in metadata ? "caom:X/\(row)" : "ivo://cadc.nrc.ca/X?\(row)/p" }
        let given = try await ProductReference.identifier(publisherID: " ivo://a ", row: nil, resolve: resolve)
        XCTAssertEqual(given, "ivo://a")
        let byRow = try await ProductReference.identifier(publisherID: nil, row: 2, resolve: resolve)
        XCTAssertEqual(byRow, "ivo://cadc.nrc.ca/X?2/p")
        let forMetadata = try await ProductReference.identifier(publisherID: "", row: 0, metadata: true, resolve: resolve)
        XCTAssertEqual(forMetadata, "caom:X/0")
        for (id, row) in [("ivo://a", 1 as Int?), (nil, nil)] {
            do {
                _ = try await ProductReference.identifier(publisherID: id, row: row, resolve: resolve)
                XCTFail("\(String(describing: id)), \(String(describing: row))")
            } catch let reason as ToolFailureReason {
                guard case .invalidArgument = reason else { return XCTFail("\(reason)") }
            }
        }
    }

    // MARK: - E. Join Plane

    func testJoinPlaneGoesBeforeWhereOrAtTheEnd() {
        let join = "JOIN caom2.Plane AS Plane ON Plane.obsID = o.obsID"
        XCTAssertEqual(ADQLIdentifier.joining(join, into: "SELECT o.observationID FROM caom2.Observation AS o WHERE o.collection = 'CFHT'"),
                       "SELECT o.observationID FROM caom2.Observation AS o \(join)\nWHERE o.collection = 'CFHT'")
        XCTAssertEqual(ADQLIdentifier.joining(join, into: "SELECT o.observationID FROM caom2.Observation AS o\n"),
                       "SELECT o.observationID FROM caom2.Observation AS o\n\(join)")
        // A WHERE in a subquery of the select list is not the query's own.
        let joined = ADQLIdentifier.joining(join, into: "SELECT o.observationID FROM caom2.Observation AS o ORDER BY o.observationID")
        XCTAssertTrue(joined.contains("\(join)\nORDER BY"), joined)
        // Then the query is of products, and runs with their publisher ID.
        XCTAssertEqual(ADQLIdentifier.ensure(joined, schema: nil).added, "Plane.publisherID AS \"Publisher ID\"")
    }
}
