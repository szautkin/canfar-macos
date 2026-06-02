// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 005: `ResearchModel.deleteObservation` removes the row from the
/// store and clears the selection — and those @Observable mutations land on
/// the MainActor after the off-actor file delete.
@MainActor
final class ResearchModelDeleteTests: XCTestCase {

    private func makeModel() -> (ResearchModel, ObservationStore) {
        let store = ObservationStore(fileName: "test-research-\(UUID().uuidString).json",
                                     spotlight: nil)
        let model = ResearchModel(
            observationStore: store,
            downloadService: DownloadService(),
            noteStore: ObservationNoteStore(database: try! AppDatabase.makeInMemory(), legacyNotesSource: nil)
        )
        return (model, store)
    }

    private func makeObservation() -> DownloadedObservation {
        // Empty columns => all string fields "", a fresh id, and a
        // non-existent localPath so the file delete is a fast no-op.
        DownloadedObservation.from(
            result: SearchResult(id: "x", rawValues: [], searchIndex: []),
            columns: SearchResultColumns(),
            localPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString).fits").path
        )
    }

    func testDeleteRemovesFromStoreAndClearsSelection() async {
        let (model, store) = makeModel()
        let obs = makeObservation()
        store.save(obs)
        model.selectedObservation = obs
        XCTAssertEqual(store.observations.count, 1)

        model.deleteObservation(obs)

        // deleteObservation spawns a Task; drain it deterministically.
        for _ in 0..<200 where !store.observations.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.observations.isEmpty, "row removed from the store")
        XCTAssertNil(model.selectedObservation, "selection cleared when it matched")
        store.clear()
    }

    /// Ticket 051: deleting an observation whose backing file is already gone
    /// must remove the row without surfacing an error to the user — the
    /// no-op/logged-failure deletion path stays silent in the UI.
    func testDeleteMissingBackingFileDoesNotSurfaceError() async {
        let (model, store) = makeModel()
        let obs = makeObservation()  // localPath points at a non-existent temp file
        store.save(obs)
        XCTAssertNil(model.lastError)

        model.deleteObservation(obs)

        for _ in 0..<200 where !store.observations.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.observations.isEmpty, "row removed despite missing file")
        XCTAssertNil(model.lastError, "missing-file deletion must not surface an error to the user")
        store.clear()
    }

    func testDeleteLeavesUnrelatedSelectionIntact() async {
        let (model, store) = makeModel()
        let toDelete = makeObservation()
        let other = makeObservation()
        store.save(toDelete)
        model.selectedObservation = other  // a different observation is selected

        model.deleteObservation(toDelete)

        for _ in 0..<200 where store.observations.contains(where: { $0.id == toDelete.id }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.observations.contains(where: { $0.id == toDelete.id }))
        XCTAssertEqual(model.selectedObservation?.id, other.id,
                       "selection must not be cleared when it didn't match the deleted row")
        store.clear()
    }

    /// P1-E: filtering also matches the NOTE text/tags (FTS), so the user can
    /// find a download by what they wrote about it — even when the observation's
    /// own metadata doesn't contain the query.
    func testFilterAlsoMatchesNoteText() async {
        let (model, store) = makeModel()
        let obs = makeObservation()   // empty metadata — won't substring-match "spiral"
        store.save(obs)
        model.noteStore.save(ObservationNote(publisherID: obs.publisherID, text: "spiral arms visible"))

        model.filterText = "spiral"
        // Debounced FTS refresh — poll the (readable) matched set.
        for _ in 0..<100 where model.noteMatchedPublisherIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.filteredObservations.contains { $0.id == obs.id },
                      "an observation whose NOTE matches is included even if its metadata doesn't")

        model.filterText = "nomatchtoken"
        for _ in 0..<100 where !model.noteMatchedPublisherIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.filteredObservations.contains { $0.id == obs.id },
                       "a non-matching query drops the note-only match")
        store.clear()
    }
}
