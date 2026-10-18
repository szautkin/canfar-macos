// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 46 M5: Move To for assistants — the sheet read, opened with a
/// choice for the person to press, and the button's moves proposed as the
/// kind of what they do, applied only while they still do it.
@MainActor
final class MoveToToolsTests: XCTestCase {
    private var state: AppState!
    private var storage: ResearchFileTransferTests.FakeStorage!
    private var folder: URL!
    private var record: DownloadedObservation!

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("move-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let downloads = folder
        DownloadsFolder.chosen.withLock { $0 = downloads }
        state = AppState()
        state.auth.apply(username: "qa-person", userInfo: nil)
        // Signing in starts the real sync and storage: this test's own instead.
        state.storageSync.signedOut()
        storage = ResearchFileTransferTests.FakeStorage()
        state.researchModel.transfer.storage = storage
        let file = folder.appendingPathComponent("745234p.cutout-qa46m5.fits")
        try Data("SIMPLE  =                    T".utf8).write(to: file)
        var made = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?745234/745234p", collection: "CFHT",
                                         observationID: "745234", targetName: "D2", instrument: "MegaPrime", filter: "r",
                                         ra: "", dec: "", startDate: "", calLevel: "2", localPath: file.path)
        made.fileSize = 30
        record = state.researchModel.observationStore.save(made)
    }

    override func tearDown() {
        if let record { state.researchModel.observationStore.remove(record) }
        state.storageSync.signedOut()
        DownloadsFolder.chosen.withLock { $0 = nil }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func proposal(_ payload: MoveResearchFilesTool.Payload) throws -> PendingProposal {
        PendingProposal(toolName: "move_research_files", kind: "move_research_files", summary: payload.summary,
                        payload: try JSONEncoder().encode(payload), origin: .external(clientID: "t"))
    }

    func testShowMoveToOpensTheSheetWithTheChoiceForThePerson() async throws {
        XCTAssertFalse(state.moveToView().open)
        let shown = try state.showMoveTo(MoveToArgs(id: record.id.uuidString, to: "storage", keepCopy: false))
        XCTAssertTrue(shown.open)
        XCTAssertEqual(shown.button, "Move to Storage")
        XCTAssertEqual(shown.files.first?.does, "move to storage")
        XCTAssertEqual(shown.files.first?.after, "storage")
        XCTAssertEqual(state.researchModel.selectedObservation?.id, record.id, "the record selected, as a click would")
        XCTAssertEqual(state.researchModel.moveTo?.plan.keepCopy, false)
        XCTAssertEqual(state.moveToView().button, "Move to Storage", "read as it shows")
        let kept = await storage.files
        XCTAssertTrue(kept.isEmpty, "nothing moves until the person presses")
    }

    func testAProposalIsTheKindOfWhatItDoes() throws {
        let copy = try state.moveResearchFilesPayload(MoveToArgs(id: record.id.uuidString))
        XCTAssertEqual(copy.removes, nil)
        XCTAssertEqual(ChangeCatalog.kind(of: try proposal(copy)), .addToStorage)
        XCTAssertEqual(copy.summary, "Copy to Storage: CFHT 745234 · D2")

        let move = try state.moveResearchFilesPayload(MoveToArgs(id: record.id.uuidString, keepCopy: false))
        XCTAssertEqual(move.removes, "mac")
        XCTAssertEqual(ChangeCatalog.kind(of: try proposal(move)), .removeFilesOnMac, "a move removes the copy here")
    }

    func testWhatMoveToWouldNotDoIsRefusedWhenAsked() {
        XCTAssertThrowsError(try state.moveResearchFilesPayload(MoveToArgs(id: record.id.uuidString, to: "mac"))) { error in
            XCTAssertTrue("\(error)".contains("already there"), "\(error)")
        }
        XCTAssertThrowsError(try state.moveResearchFilesPayload(MoveToArgs(id: record.id.uuidString, files: ["other.fits"]))) { error in
            XCTAssertTrue("\(error)".contains("has no file other.fits"), "\(error)")
        }
        XCTAssertThrowsError(try state.moveResearchFilesPayload(MoveToArgs(id: "not-a-record")))
    }

    func testAppliedItMovesAndOnlyWhileItStillDoesWhatWasAsked() async throws {
        let payload = try state.moveResearchFilesPayload(MoveToArgs(id: record.id.uuidString))
        let extra = try await state.applyMoveResearchFiles(payload)
        XCTAssertEqual(extra.note, "places now — 745234p.cutout-qa46m5.fits: both")
        XCTAssertEqual(state.researchModel.observationStore.observation(id: record.id)?.mainKeptFile?.places,
                       FilePlaces(onMac: true, inStorage: true))
        do {
            _ = try await state.applyMoveResearchFiles(payload)
            XCTFail("the files are not where they were when it was asked")
        } catch {
            XCTAssertTrue("\(error)".contains("not where they were"), "\(error)")
        }
    }

    /// Live, plan 46 L8: the tool told an assistant a move "applies at once"
    /// — its tool's kind — while the move waited as a removal.
    func testItsDescriptionSaysItsKindIsWhatEachCallDoes() {
        for tool in ["move_research_files", "resolve_sync_conflict"] {
            let rule = state.agentsService.toolRule(tool) ?? ""
            XCTAssertTrue(rule.contains("what each call does"), "\(tool): \(rule)")
            XCTAssertFalse(rule.contains("allows it without asking"), "not one kind for every call: \(tool): \(rule)")
        }
        XCTAssertTrue(state.agentsService.toolRule("save_query")?.contains("Notes and saved things") == true, "others keep theirs")
    }
}
