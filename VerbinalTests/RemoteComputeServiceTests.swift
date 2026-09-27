// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Remote compute as the screen and the assistant's tools share it: the
/// state, the session, the runs remembered, and the answers the tools give.
@MainActor
final class RemoteComputeServiceTests: XCTestCase {

    private var sessions = FakeComputeSessions()
    private var files = FakeComputeFiles()
    private var image = "images.canfar.net/p/compute:1"
    private var user = "me"

    private func service(poll: Duration = .milliseconds(10), allowance: TimeInterval = 5 * 60) -> RemoteComputeService {
        RemoteComputeService(
            runs: ComputeRunStore(persistence: nil), sessions: sessions, files: files,
            username: { [unowned self] in user }, configuration: { [unowned self] in .init(image: image, cores: 2, ram: 8) },
            registryAuth: { ("robot", "s3cret") }, pollInterval: poll, startupAllowance: allowance)
    }

    private func request(_ id: String = "r1", code: String = "print(1)\r\n", timeout: Int = 60) -> RunCodeContract.Request {
        RunCodeContract.Request(id: id, language: "python", code: code, timeout_seconds: timeout)
    }

    // MARK: - The state

    func testTheStateFollowsTheSessionSetUpOrNot() {
        XCTAssertEqual(ComputeState(configured: false, sessionStatus: nil), .notSetUp)
        XCTAssertEqual(ComputeState(configured: true, sessionStatus: " "), .stopped)
        XCTAssertEqual(ComputeState(configured: true, sessionStatus: "Pending"), .starting)
        XCTAssertEqual(ComputeState(configured: false, sessionStatus: "Running"), .running, "a session is what it is, set up here or not")
        XCTAssertEqual(ComputeState(configured: true, sessionStatus: "Terminating"), .stopping)
        XCTAssertEqual(ComputeState(configured: true, sessionStatus: "Error"), .failed)
        XCTAssertEqual(ComputeState(configured: true, sessionStatus: "Succeeded"), .stopped, "a finished session holds nothing")

        XCTAssertTrue(ComputeState.failed.canStart(configured: true))
        XCTAssertFalse(ComputeState.running.canStart(configured: true))
        XCTAssertFalse(ComputeState.stopped.canStart(configured: false))
        XCTAssertTrue(ComputeState.failed.canStop)
        XCTAssertFalse(ComputeState.stopping.canStop)
        XCTAssertTrue(ComputeState.stopped.canRun(configured: true), "a stopped session is started for the run")
        XCTAssertFalse(ComputeState.stopping.canRun(configured: true))
    }

    func testUptimeIsFromThePlatformsStartAndNeverNegative() {
        let now = SharedFormatters.isoDate("2026-06-05T01:30:00Z")!
        XCTAssertEqual(ComputeState.uptime(startedAt: "2026-06-05T00:00:00Z", now: now), 90 * 60)
        XCTAssertEqual(ComputeState.uptime(startedAt: "2026-06-05T01:00:00.500Z", now: now), 29 * 60 + 59.5)
        XCTAssertNil(ComputeState.uptime(startedAt: "2026-06-05T02:00:00Z", now: now))
        XCTAssertNil(ComputeState.uptime(startedAt: "soon", now: now))
    }

    func testASessionLeftFromElsewhereIsSeenEvenWhenNotSetUp() async throws {
        image = ""
        sessions = FakeComputeSessions([.compute(id: "old", status: "Failed"), .compute(id: "live", status: "Running"),
                                        .compute(id: "nb", status: "Running", name: "mine", type: "notebook")])
        let snapshot = try await service().snapshot()
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.session?.id, "live", "a live one wins over a dead one")
        let answer = GetComputeStateTool.Output(snapshot)
        XCTAssertFalse(answer.configured)
        XCTAssertNil(answer.image)
        XCTAssertTrue(answer.note?.contains("stop_compute") == true)
        XCTAssertEqual(answer.sessionCores, "2")
        XCTAssertEqual(answer.sessionRam, "8G")

        user = ""
        let signedOut = try await service().snapshot()
        XCTAssertNil(signedOut.session, "signed out, there is no session to look for")
        XCTAssertEqual(signedOut.state, .notSetUp)
    }

    // MARK: - The session

    func testASessionIsReusedOrLaunchedWithTheRegistryCredentials() async throws {
        let compute = service()
        let reused = try await compute.ensureSession()
        XCTAssertFalse(reused)
        XCTAssertEqual(sessions.launched.map(\.image), [image])
        XCTAssertEqual(sessions.launched.first?.cores, 2)
        XCTAssertEqual(sessions.launched.first?.registryUsername, "robot")
        XCTAssertEqual(files.folders, [".verbinal", ".verbinal/exec", ".verbinal/exec/inbox", ".verbinal/exec/out"])
        let again = try await compute.ensureSession()
        XCTAssertTrue(again, "a starting session is reused, not launched beside")
        XCTAssertEqual(sessions.launched.count, 1)

        let stopped = try await compute.stop()
        XCTAssertTrue(stopped)
        XCTAssertEqual(sessions.deleted, ["launched-1"])
        let stoppedAgain = try await compute.stop()
        XCTAssertFalse(stoppedAgain, "nothing left to stop")
    }

    func testNothingLaunchesWithoutAnImageOrSomeoneSignedIn() async {
        image = ""
        do {
            try await service().ensureSession()
            XCTFail("not set up")
        } catch {
            XCTAssertEqual(error as? RemoteComputeError, .notSetUp)
        }
        image = "i:1"
        user = ""
        do {
            try await service().submit(request(), by: .user)
            XCTFail("signed out")
        } catch {
            XCTAssertEqual(error as? RemoteComputeError, .signedOut)
        }
        XCTAssertTrue(sessions.launched.isEmpty)
    }

    // MARK: - Runs

    func testARunIsSentRememberedAndSettledByWhoeverReadsItsResult() async throws {
        let compute = service(poll: .seconds(60))
        try await compute.submit(request(), by: .user)
        let sent = try XCTUnwrap(files.uploads[RunCodeContract.inboxPath(id: "r1")])
        let wire = try JSONDecoder().decode(RunCodeContract.Request.self, from: sent)
        XCTAssertEqual(wire.code, "print(1)\n", "Unix line endings on the wire")
        XCTAssertEqual(compute.runs.runs.map(\.author), [.user])
        XCTAssertEqual(compute.runs.find("R1")?.state, ComputeRun.running)

        let absent = try await compute.fetchOut("r1")
        XCTAssertEqual(absent, .absent)
        files.put(RunCodeContract.outPath(id: "r1"), "{ partial")
        let partial = try await compute.fetchOut("r1")
        XCTAssertEqual(partial, .incomplete)
        files.put(RunCodeContract.outPath(id: "r1"), #"{"status":"OK","exit_code":0,"stdout":"MQo=","stdout_encoding":"base64","duration_ms":12}"#)
        guard case .done(let result) = try await compute.fetchOut("r1") else { return XCTFail() }
        XCTAssertEqual(result.decodedStdout, "1\n")
        let run = try XCTUnwrap(compute.runs.find("r1"))
        XCTAssertEqual(run.status, "ok")
        XCTAssertEqual(run.durationMs, 12)
        XCTAssertNotNil(run.finishedAt)
        compute.stopWatching()
    }

    func testARunThatCannotBeSentSaysSo() async {
        files.failUploads = true
        let compute = service()
        do {
            try await compute.submit(request(), by: .agent)
            XCTFail("the upload fails")
        } catch {}
        XCTAssertEqual(compute.runs.find("r1")?.status, ComputeRun.notSent)
    }

    func testAWatchedRunSettlesOnItsOwnOrIsGivenUpOn() async throws {
        let compute = service(allowance: 0.2)
        try await compute.submit(request("done", timeout: 1), by: .agent)
        try await compute.submit(request("lost", timeout: 1), by: .agent)
        files.put(RunCodeContract.outPath(id: "done"), #"{"status":"error","exit_code":1}"#)
        for _ in 0..<200 where compute.runs.runs.contains(where: { !$0.isFinished }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(compute.runs.find("done")?.status, "error")
        XCTAssertEqual(compute.runs.find("lost")?.status, ComputeRun.noResult, "nothing back in the time it could take")
    }

    // MARK: - The history

    func testTheHistoryKeepsTheNewestAndChangesNothingOnARereadResult() {
        let store = ComputeRunStore(persistence: nil)
        for index in 0...ComputeRunStore.maxRuns {
            store.add(ComputeRun(request("r\(index)"), author: .agent))
        }
        XCTAssertEqual(store.runs.count, ComputeRunStore.maxRuns)
        XCTAssertEqual(store.runs.first?.id, "r\(ComputeRunStore.maxRuns)")
        XCTAssertNil(store.find("r0"))

        let result = RunCodeContract.ResultFile(id: nil, status: " ", exit_code: 2, stdout: nil, stdout_encoding: nil, stderr: nil,
                                                stderr_encoding: nil, duration_ms: nil, truncated: nil, started_at: nil, finished_at: nil)
        store.complete("r5", with: result)
        let first = store.find("r5")
        XCTAssertEqual(first?.status, "error", "no verdict is an error")
        store.complete("r5", with: result)
        XCTAssertEqual(store.find("r5"), first)
        store.close("r5", as: ComputeRun.noResult)
        XCTAssertEqual(store.find("r5")?.status, "error", "a finished run is not closed again")
    }

    // MARK: - list_compute_runs

    private struct Listed: Decodable {
        let total: Int
        let runs: [Entry]
        struct Entry: Decodable { let executionId: String; let author: String; let status: String; let codePreview: String; let codeLength: Int }
    }

    func testListingRunsQuotesTheStartOfEachNewestFirst() async throws {
        var long = ComputeRun(request("big", code: String(repeating: "x", count: 1000)), author: .user)
        long.status = "ok"
        let runs = [long, ComputeRun(request("small"), author: .agent)]
        let tool = ListComputeRunsTool(runs: { runs })
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        guard case .data(let data) = await tool.invoke(arguments: Data(#"{"limit":1}"#.utf8), context: ctx) else { return XCTFail() }
        let listed = try JSONDecoder().decode(Listed.self, from: data)
        XCTAssertEqual(listed.total, 2)
        XCTAssertEqual(listed.runs.map(\.executionId), ["big"])
        XCTAssertEqual(listed.runs[0].author, "user")
        XCTAssertEqual(listed.runs[0].codePreview.count, ListComputeRunsTool.previewLength)
        XCTAssertEqual(listed.runs[0].codeLength, 1000)
    }
}
