// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// The Remote Compute screen: what it lets the person do in each state,
/// the runs and their output, and what an agent reads and puts on it.
@MainActor
final class RemoteComputeScreenTests: XCTestCase {

    private var sessions = FakeComputeSessions()
    private var files = FakeComputeFiles()
    private var image = "images.canfar.net/p/compute:1"

    private func model() -> RemoteComputeModel {
        RemoteComputeModel(service: RemoteComputeService(
            runs: ComputeRunStore(persistence: nil), sessions: sessions, files: files,
            username: { "me" }, configuration: { [unowned self] in .init(image: image, cores: 2, ram: 8) },
            registryAuth: { nil }, pollInterval: .seconds(60)))
    }

    func testWhatTheScreenOffersFollowsTheState() async {
        let screen = model()
        await screen.refresh()
        XCTAssertEqual(screen.state, .stopped)
        XCTAssertTrue(screen.canStart)
        XCTAssertFalse(screen.canStop)
        XCTAssertTrue(screen.canRun, "a stopped session is started for the run")

        await screen.start()
        XCTAssertEqual(screen.state, .starting)
        XCTAssertFalse(screen.canStart)
        XCTAssertTrue(screen.canStop)
        XCTAssertTrue(screen.isChanging)
        XCTAssertEqual(screen.message?.kind, .info)

        await screen.stop()
        XCTAssertEqual(screen.state, .stopped)
        XCTAssertEqual(sessions.deleted.count, 1)
    }

    func testASessionFromElsewhereIsShownToStopWhenNotSetUp() async {
        image = ""
        sessions = FakeComputeSessions([.compute(id: "old", status: "Running")])
        let screen = model()
        await screen.refresh()
        XCTAssertFalse(screen.isConfigured)
        XCTAssertTrue(screen.hasSession)
        XCTAssertTrue(screen.canStop)
        XCTAssertFalse(screen.canRun)
        XCTAssertEqual(screen.message?.kind, .info)
    }

    func testRunningTheBoxSelectsTheRunAndShowsItsOutputOnceBack() async throws {
        let screen = model()
        screen.setSnippet(code: "echo hi", language: "BASH", timeoutSeconds: 5000)
        XCTAssertEqual(screen.language, "python", "an unknown language falls back")
        XCTAssertEqual(screen.timeoutSeconds, RunCodeContract.maxTimeoutSeconds)
        XCTAssertEqual(screen.tab, .code)
        screen.language = "bash"
        await screen.runSnippet()

        let run = try XCTUnwrap(screen.selectedRun)
        XCTAssertEqual(run.author, .user)
        XCTAssertEqual(run.language, "bash")
        XCTAssertEqual(screen.tab, .run)
        await screen.loadOutput()
        XCTAssertEqual(screen.output, .waiting)

        files.put(RunCodeContract.outPath(id: run.id), #"{"status":"ok","exit_code":0,"stdout":"hi\n","stderr":"warn","truncated":true}"#)
        _ = try await screen.service.fetchOut(run.id)
        await screen.loadOutput()
        XCTAssertEqual(screen.output, .text(stdout: "hi\n", stderr: "warn", truncated: true))
        XCTAssertEqual(RemoteComputeView.meta(of: try XCTUnwrap(screen.selectedRun), truncated: true).components(separatedBy: " · ").count, 3)

        await screen.runAgain()
        XCTAssertEqual(screen.runs.count, 2)
        XCTAssertNotEqual(screen.selectedRunID, run.id, "the new run is the one shown")
        screen.service.stopWatching()
    }

    func testAnAgentReadsTheScreenAsItStands() async {
        let screen = model()
        screen.setSnippet(code: "print(1)\r\n", language: "python", timeoutSeconds: 30)
        let view = screen.view(shown: true)
        XCTAssertEqual(view.tab, "code")
        XCTAssertEqual(view.snippet, .init(language: "python", timeoutSeconds: 30, code: "print(1)\n"))
        XCTAssertNil(view.selectedRun)
        XCTAssertEqual(view.state, "stopped")
    }

    func testTheScreensToolsNeedSomeoneSignedIn() async {
        let state = AppState(marks: MarkStore(persistence: nil), userImages: UserImageStore(persistence: nil))
        guard !state.isAuthenticated else { return }
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        guard case .failed(.targetNotResolved) = await state.makeShowComputeRunTool().invoke(arguments: Data("{}".utf8), context: ctx) else {
            return XCTFail()
        }
        guard case .failed(.invalidArgument) = await state.makeSetComputeSnippetTool().invoke(arguments: Data(#"{"code":" "}"#.utf8), context: ctx) else {
            return XCTFail()
        }
        guard case .failed(.targetNotResolved) = await state.makeShowStorageFolderTool().invoke(arguments: Data("{}".utf8), context: ctx) else {
            return XCTFail()
        }
        guard case .data = await state.makeGetComputeViewTool().invoke(arguments: Data("{}".utf8), context: ctx) else { return XCTFail() }
        XCTAssertNotEqual(state.currentMode, .remoteCompute)
    }

    func testAStorageFolderIsOnlyEverInThePersonsHome() {
        XCTAssertEqual(ShowStorageFolderTool.homeRelative(" .verbinal/exec/ ", username: "me"), ".verbinal/exec")
        XCTAssertEqual(ShowStorageFolderTool.homeRelative("", username: "me"), "")
        XCTAssertEqual(ShowStorageFolderTool.homeRelative("/me", username: "me"), "")
        XCTAssertEqual(ShowStorageFolderTool.homeRelative("/me/data/run1", username: "me"), "data/run1")
        XCTAssertEqual(ShowStorageFolderTool.homeRelative("me/data", username: "me"), "me/data", "relative: a folder named like its owner")
        XCTAssertNil(ShowStorageFolderTool.homeRelative("/someone/data", username: "me"))
        XCTAssertNil(ShowStorageFolderTool.homeRelative("/meadow", username: "me"))
    }

    func testModesHaveOneNameForAgents() {
        for mode in AppMode.allCases {
            XCTAssertEqual(AppMode(key: mode.key), mode)
            XCTAssertFalse(mode.title.isEmpty)
        }
        XCTAssertTrue(AppMode.remoteCompute.requiresAuthentication)
        XCTAssertNil(AppMode(key: "compute"))
    }
}
