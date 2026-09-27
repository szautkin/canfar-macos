// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Research records without their file: kept to read about, a file removed
/// while the observation stays, and a download into the same record.
@MainActor
final class ResearchRecordTests: XCTestCase {

    private var fileName = ""
    private var tempFiles: [URL] = []

    override func setUp() {
        fileName = "test-research-records-\(UUID().uuidString).json"
    }

    override func tearDown() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Verbinal")
        if let dir { try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName)) }
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func store() -> ObservationStore {
        ObservationStore(fileName: fileName, spotlight: nil)
    }

    private func record(_ pid: String = "ivo://cadc.nrc.ca/CFHT?2388466/2388466p", path: String = "") -> DownloadedObservation {
        DownloadedObservation(publisherID: pid, collection: "CFHT", observationID: "2388466", targetName: "M31",
                              instrument: "MegaPrime", filter: "r", ra: "", dec: "", startDate: "", calLevel: "2",
                              localPath: path)
    }

    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("research-\(UUID().uuidString).fits")
        try Data("SIMPLE  =".utf8).write(to: url)
        tempFiles.append(url)
        return url
    }

    // MARK: - The record

    func testAPublisherIDNamesItsCollectionAndObservation() throws {
        let id = try XCTUnwrap(PublisherID("ivo://cadc.nrc.ca/CFHT?2388466/2388466p"))
        XCTAssertEqual([id.collection, id.observationID, id.productID], ["CFHT", "2388466", "2388466p"])
        XCTAssertEqual(PublisherID("ivo://cadc.nrc.ca/HST?j8xa01010")?.productID, "")
        XCTAssertNil(PublisherID("M31"))
        XCTAssertNil(PublisherID("ivo://cadc.nrc.ca/CFHT"))
    }

    /// No file means no path at all — never the working directory an empty
    /// path resolves to, which a delete would then be aimed at.
    func testARecordWithoutAFileHasNoPath() {
        let kept = record()
        XCTAssertFalse(kept.isDownloaded)
        XCTAssertNil(kept.localURL)
        XCTAssertNil(kept.resolvedReadableURL)
        XCTAssertFalse(kept.fileExists)
        XCTAssertEqual(kept.filename, "")
    }

    // MARK: - The store

    func testKeepingAnObservationLeavesOneAlreadyThereAsItIs() {
        let research = store()
        let first = research.keep(record())
        XCTAssertTrue(first.added)
        XCTAssertFalse(first.record.isDownloaded)
        var other = record()
        other.targetName = "changed"
        let second = research.keep(other)
        XCTAssertFalse(second.added)
        XCTAssertEqual(second.record.id, first.record.id)
        XCTAssertEqual(research.observations.map(\.targetName), ["M31"])
    }

    /// A download into a kept record is the same record, so its id still works.
    func testADownloadGoesIntoTheSameRecord() throws {
        let research = store()
        let kept = research.keep(record()).record
        let stored = research.save(record(path: try tempFile().path))
        XCTAssertEqual(stored.id, kept.id)
        XCTAssertEqual(research.observations.count, 1)
        XCTAssertTrue(research.observations[0].isDownloaded)
        XCTAssertEqual(store().observations.first?.id, kept.id, "and on disk")
    }

    func testForgettingAFileKeepsTheObservation() throws {
        let research = store()
        let saved = research.save(record(path: try tempFile().path))
        let kept = try XCTUnwrap(research.forgetFile(of: saved.id))
        XCTAssertFalse(kept.isDownloaded)
        XCTAssertNil(kept.bookmarkData)
        XCTAssertEqual(kept.targetName, "M31")
        XCTAssertNil(research.forgetFile(of: UUID()))
    }

    func testARecordIsFoundByAnyOfItsNames() {
        let research = store()
        let kept = research.keep(record()).record
        _ = research.keep(record("ivo://cadc.nrc.ca/CFHT?999/999p"))
        XCTAssertEqual(research.record(identifiedBy: kept.id.uuidString)?.id, kept.id)
        XCTAssertEqual(research.record(identifiedBy: String(kept.id.uuidString.prefix(8)))?.id, kept.id)
        XCTAssertEqual(research.record(identifiedBy: "ivo://cadc.nrc.ca/CFHT?2388466/2388466p")?.id, kept.id)
        XCTAssertNil(research.record(identifiedBy: "2388466"), "two records share that observation id")
        XCTAssertNil(research.record(identifiedBy: "nope"))
    }

    // MARK: - The model

    func testRemovingAFileDeletesItAndKeepsTheSelection() async throws {
        let research = store()
        let model = ResearchModel(observationStore: research, downloadService: DownloadService(),
                                  noteStore: ObservationNoteStore(database: try AppDatabase.makeInMemory(), legacyNotesSource: nil))
        let file = try tempFile()
        let saved = research.save(record(path: file.path))
        model.selectedObservation = saved
        XCTAssertTrue(model.isDownloaded(publisherID: saved.publisherID))

        try await model.removeFile(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(model.selectedObservation?.id, saved.id)
        XCTAssertEqual(model.selectedObservation?.isDownloaded, false, "the detail shows it without its file")
        XCTAssertFalse(model.isDownloaded(publisherID: saved.publisherID))
        XCTAssertTrue(model.isInResearch(publisherID: saved.publisherID))
    }

    // MARK: - The tools

    func testSavingFromAPublisherIDAloneReadsItsParts() {
        let saved = SaveObservationToResearchTool.record(from: .init(publisherId: "ivo://cadc.nrc.ca/JCMT?scuba2_00012/raw"))
        XCTAssertEqual(saved.collection, "JCMT")
        XCTAssertEqual(saved.observationID, "scuba2_00012")
        XCTAssertFalse(saved.isDownloaded)
    }

    func testTheToolsPlanWhatTheySay() async throws {
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        let save = try await SaveObservationToResearchTool().plan(.init(publisherId: "  ivo://x/Y?1/2 ", targetName: "M31"), context: ctx)
        XCTAssertEqual(try JSONDecoder().decode(SaveObservationToResearchTool.Payload.self, from: save.payload).publisherId, "ivo://x/Y?1/2")
        XCTAssertTrue(save.summary.contains("without its file"))
        XCTAssertEqual(RemoveDownloadedFileTool.verbClass, .destructive, "deleting a file always waits for the person")
        do {
            _ = try await RemoveDownloadedFileTool().plan(.init(id: "  "), context: ctx)
            XCTFail("an empty id")
        } catch {}
    }
}
