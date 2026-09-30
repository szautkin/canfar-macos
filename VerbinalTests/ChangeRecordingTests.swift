// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 23 C: every change is recorded by the one that makes it — the
/// person's through the screen, the app's by its rules — and an
/// assistant's where it is applied, never twice.
@MainActor
final class ChangeRecordingTests: XCTestCase {

    /// A log and what it heard.
    final class Heard: @unchecked Sendable {
        let log = ChangeLog()
        private let lock = NSLock()
        private var list: [Change] = []
        init() { log.observe { [weak self] change in self?.lock.withLock { self?.list.append(change) } } }
        var changes: [Change] { lock.withLock { list } }
        var sentences: [String] { changes.map(\.sentence) }
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func answering(_ status: Int, _ body: String = "") {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private var network: NetworkClient { NetworkClient(session: MockURLProtocol.mockSession()) }

    // MARK: - The guardrail

    /// Every kind of change an assistant can propose has a verb — a new
    /// write tool whose kind names none fails here, and gets a row.
    func testEveryRegisteredChangeKindHasAVerb() async throws {
        let state = AppState()
        _ = state.makeAgentTools()
        var kinds: [String] = []
        for _ in 0..<50 where kinds.isEmpty {
            kinds = await state.agentsService.applierRegistry.registeredKinds()
            if kinds.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertGreaterThan(kinds.count, 30, "the appliers were not registered")
        XCTAssertEqual(kinds.filter { ChangeVerb.of(kind: $0) == nil }, [], "kinds without a verb in ChangeVerb.table")
    }

    // MARK: - Sessions and batch jobs

    func testSessionChangesAreRecordedAtThePlatformService() async throws {
        let heard = Heard()
        let sessions = SessionService(network: network, changes: heard.log)
        answering(200, #"["abc123"]"#)
        _ = try await sessions.launchSession(SessionLaunchParams(type: "notebook", name: "mine", image: "images.canfar.net/skaha/astroml:latest"))
        try await sessions.renewSession(id: "abc123")
        try await sessions.deleteSession(id: "abc123")
        XCTAssertEqual(heard.sentences, [
            "Launched notebook session mine (images.canfar.net/skaha/astroml:latest)",
            "Renewed session abc123",
            "Deleted session abc123",
        ])
        XCTAssertEqual(heard.changes.map(\.startedBy), [.person, .person, .person])
    }

    func testAFailedDeleteSaysWhy() async {
        let heard = Heard()
        answering(500, "boom")
        _ = try? await SessionService(network: network, changes: heard.log).deleteSession(id: "gone")
        XCTAssertEqual(heard.changes.first?.outcome, .failed)
        XCTAssertTrue(heard.changes.first?.failure?.contains("500") == true, "\(String(describing: heard.changes.first?.failure))")
    }

    func testABatchJobIsRecordedWhoeverLaunchesIt() async throws {
        let heard = Heard()
        answering(200, #"["job1"]"#)
        _ = try await Initiator.$current.withValue(.app) {
            try await HeadlessService(network: network, changes: heard.log)
                .launchHeadlessJob(HeadlessLaunchParams(name: "probe", image: "images.canfar.net/skaha/terminal:1.1.2"))
        }
        XCTAssertEqual(heard.sentences, ["Launched batch job probe (images.canfar.net/skaha/terminal:1.1.2)"])
        XCTAssertEqual(heard.changes.first?.startedBy, .app)
    }

    /// Inside an assistant's apply the owner is silent: the apply records it.
    func testAnOwnerDoesNotRecordAnAppliedProposalAgain() async throws {
        let heard = Heard()
        answering(200)
        let proposal = PendingProposal(toolName: "delete_session", kind: "delete_session", summary: "Delete session abc",
                                       payload: Data(), origin: .external(clientID: "test/1"), why: "done with it")
        try await heard.log.applying(proposal, by: .autoApply) {
            try await SessionService(network: network, changes: heard.log).deleteSession(id: "abc")
        }
        XCTAssertEqual(heard.sentences, ["Deleted session abc"])
        XCTAssertEqual(heard.changes.first?.cause.appliedBy, .autoApply)
        XCTAssertEqual(heard.changes.first?.cause.why, "done with it")
    }

    // MARK: - Storage

    func testStorageChangesAreRecorded() async throws {
        let heard = Heard()
        let storage = VOSpaceBrowserService(network: network, changes: heard.log)
        answering(201)
        try await storage.createFolder(username: "someone", parentPath: "data", folderName: "run2")
        answering(200)
        try await storage.deleteNode(username: "someone", path: "data/old.fits")
        XCTAssertEqual(heard.sentences, ["Made folder data/run2 in storage", "Deleted data/old.fits in storage"])
    }

    // MARK: - Research

    func testResearchChangesAreRecorded() throws {
        let heard = Heard()
        let store = ObservationStore(fileName: "test_changes_\(UUID().uuidString).json", spotlight: nil, changes: heard.log)
        let record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?1525350/1525350o", collection: "CFHT",
                                           observationID: "1525350", targetName: "M31", instrument: "", filter: "",
                                           ra: "", dec: "", startDate: "", calLevel: "", localPath: "")
        let kept = store.keep(record).record
        _ = store.keep(record)  // kept already: no second change
        store.remove(kept)
        XCTAssertEqual(heard.sentences, ["Saved M31 (1525350, CFHT) to Research", "Deleted Research record M31 (1525350, CFHT)"])
    }

    func testSavedQueryChangesAreRecorded() {
        let heard = Heard()
        let store = SavedQueryStore(fileName: "test_changes_\(UUID().uuidString).json", changes: heard.log)
        var query = SavedQuery(name: "JWST M31", adql: "SELECT 1")
        store.save(query)
        query.adql = "SELECT 2"
        store.save(query)
        store.remove(query)
        XCTAssertEqual(heard.sentences, ["Saved the query \"JWST M31\"", "Updated the query \"JWST M31\"", "Deleted the saved query \"JWST M31\""])
    }

    // MARK: - Marks, images, bookmarks

    func testMarkChangesAreRecorded() throws {
        let heard = Heard()
        let marks = MarkStore(persistence: nil, changes: heard.log)
        let target = MarkStore.Target(file: URL(fileURLWithPath: "/data/m31.fits"), hdu: 1)
        let mark = Mark(id: marks.newID(on: target), kind: .circle, anchor: .init(space: .imagePixel, x: 10, y: 20),
                        extent: .square(5), author: .user, createdAt: Date())
        try marks.add(mark, to: target)
        try marks.remove(mark.id, from: target)
        XCTAssertEqual(heard.sentences, ["Added mark \(mark.id) on m31.fits, extension 1",
                                         "Removed mark \(mark.id) from m31.fits, extension 1"])
    }

    func testImagesAndBookmarksAreRecorded() {
        let heard = Heard()
        let images = UserImageStore(persistence: nil, changes: heard.log)
        images.add(RegistryImage(id: "images.canfar.net/me/tool:1", types: ["notebook"]))
        images.remove("images.canfar.net/me/tool:1")
        let bookmarks = BookmarkStore(fileName: "test_changes_\(UUID().uuidString).json", changes: heard.log)
        let bookmark = CoordinateBookmark(label: "core", ra: 10.68, dec: 41.27, sourceFilePath: "/data/m31.fits")
        bookmarks.save(bookmark)
        bookmarks.delete(bookmark)
        XCTAssertEqual(heard.sentences, [
            "Added the image images.canfar.net/me/tool:1 to the launch list",
            "Removed the image images.canfar.net/me/tool:1 from the launch list",
            "Saved the sky bookmark \"core\"",
            "Deleted the sky bookmark \"core\"",
        ])
    }

    // MARK: - Workflows and the AI Guide

    func testWorkflowChangesAreRecordedOnceEach() throws {
        let heard = Heard()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory, builtins: { [("cfht", "# CFHT imaging recon\n- [ ] **Step**\n")] },
                                  changes: heard.log)
        let copy = try store.useWorkflow("builtin:cfht")
        try store.setStepDone(copy, index: 0, done: true)
        try store.delete(copy)
        XCTAssertEqual(heard.sentences, [
            "Used a copy of the workflow \"CFHT imaging recon\" as \"CFHT imaging recon\"",
            "Set step 1 of the workflow \"CFHT imaging recon\" done",
            "Deleted the workflow \"CFHT imaging recon\"",
        ])
    }

    func testAIGuideChangesAreRecorded() throws {
        let heard = Heard()
        let guide = AIGuideService(database: try .makeInMemory(), changes: heard.log)
        let entry = try guide.addGuide(name: "house-rules", description: "Our rules.", body: "Be kind.")
        guide.deleteGuide(id: entry.id)
        XCTAssertEqual(heard.sentences, ["Added the guide house_rules for assistants", "Deleted the guide house_rules for assistants"], "as it is stored")
    }
}
