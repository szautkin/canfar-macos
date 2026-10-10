// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 36 2.10 (flow review G3): list_downloaded_observations finds the
/// records the Research screen's filter finds — by a word of a note or a
/// tag too — and says each one's tags and rating.
@MainActor
final class ResearchFilterTests: XCTestCase {

    private func record(_ id: String, target: String, collection: String = "CFHT") -> DownloadedObservation {
        DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/\(collection)?\(id)/\(id)", collection: collection,
                              observationID: id, targetName: target, instrument: "MegaPrime", filter: "",
                              ra: "", dec: "", startDate: "", calLevel: "", localPath: "")
    }

    func testTheScreenAndTheToolFindTheSameRecords() async throws {
        let store = ObservationStore(fileName: "test-filter-\(UUID().uuidString).json", spotlight: nil)
        let notes = ObservationNoteStore(database: try AppDatabase.makeInMemory(), legacyNotesSource: nil)
        let m31 = store.keep(record("1001", target: "M31")).record
        let ngc = store.keep(record("1002", target: "NGC 300")).record
        _ = store.keep(record("1003", target: "Vega", collection: "JWST"))
        notes.save(ObservationNote(publisherID: ngc.publisherID, text: "transit candidate, odd dip", rating: 4, tags: ["Candidate"]))

        let model = ResearchModel(observationStore: store, downloadService: DownloadService(), noteStore: notes)
        model.filterText = "transit"
        try await Task.sleep(for: .milliseconds(400))  // the note search is debounced
        XCTAssertEqual(model.filteredObservations.map(\.id), [ngc.id])

        let tool = AppState().makeListDownloadedObservationsTool(store: store, notes: notes)
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        func ids(_ args: String) async throws -> [String] {
            guard case .data(let data) = await tool.invoke(arguments: Data(args.utf8), context: ctx) else { return ["?"] }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (object["entries"] as? [[String: Any]] ?? []).compactMap { $0["observationID"] as? String }.sorted()
        }
        let byNote = try await ids(#"{"text":"transit"}"#)
        XCTAssertEqual(byNote, ["1002"], "a word of the note, as on screen")
        let byTarget = try await ids(#"{"text":" m31 "}"#)
        XCTAssertEqual(byTarget, ["1001"])
        let byTag = try await ids(#"{"tag":"candidate"}"#)
        XCTAssertEqual(byTag, ["1002"], "a tag, whole, any case")
        let byCollectionAndWord = try await ids(#"{"collection":"cfht","text":"megaprime"}"#)
        XCTAssertEqual(byCollectionAndWord, ["1001", "1002"])
        XCTAssertEqual(ResearchFilter("megaprime", noteMatches: []).keeps(m31), true)

        guard case .data(let data) = await tool.invoke(arguments: Data(#"{"tag":"Candidate"}"#.utf8), context: ctx) else { return XCTFail() }
        let entry = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["entries"] as? [[String: Any]]).first
        XCTAssertEqual(entry?["tags"] as? [String], ["Candidate"])
        XCTAssertEqual(entry?["rating"] as? Int, 4)
    }
}
