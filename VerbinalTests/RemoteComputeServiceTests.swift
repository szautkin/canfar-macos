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

    // MARK: - A session older than Settings (plan 15 S6, QA M7)

    /// The reported case: Settings say 0.0.1, 4 cores, 8 GB; the session
    /// runs 0.0.2 with 1 core and 1.07 GB.
    func testASessionThatDiffersFromSettingsSaysHow() throws {
        let settings = RemoteComputeService.Configuration(image: "images.canfar.net/verbinal/verbinal-execution:0.0.1", cores: 4, ram: 8)
        let older = Session.compute(id: "kedczixz", status: "Running", image: "images.canfar.net/verbinal/verbinal-execution:0.0.2",
                                    ram: "1.07G", cores: "1")
        let drift = try XCTUnwrap(ComputeDrift(session: older, configuration: settings))
        XCTAssertEqual(drift.differences, [
            "runs images.canfar.net/verbinal/verbinal-execution:0.0.2, not images.canfar.net/verbinal/verbinal-execution:0.0.1",
            "has 1 of the 4 cores Settings ask",
            "has 1.07 of the 8 GB Settings ask",
        ])
        XCTAssertTrue(drift.sentence.hasSuffix("until it is stopped and started again."))

        let same = Session.compute(id: "s", status: "Running", image: settings.image, ram: "8Gi", cores: "4")
        XCTAssertNil(ComputeDrift(session: same, configuration: settings))
        let gone = Session.compute(id: "g", status: "Succeeded", image: "other:1")
        XCTAssertNil(ComputeDrift(session: gone, configuration: settings), "only a live session is compared")

        let answer = GetComputeStateTool.Output(ComputeSnapshot(state: .running, session: older, configuration: settings))
        XCTAssertTrue(answer.drift?.contains("stop_compute") == true)
    }

    func testMemoryAndCoresAsThePlatformWritesThem() {
        XCTAssertEqual(PlatformMemory.gigabytes("8G"), 8)
        XCTAssertEqual(PlatformMemory.gigabytes("8Gi"), 8)
        XCTAssertEqual(PlatformMemory.gigabytes("1.07G"), 1.07)
        XCTAssertEqual(PlatformMemory.gigabytes("512M"), 0.5)
        XCTAssertEqual(PlatformMemory.gigabytes("8.59")!, 8, accuracy: 0.01, "a bare number: GB of the GiB asked")
        XCTAssertNil(PlatformMemory.gigabytes(""))
        XCTAssertEqual(ComputeDrift.cores("1.0"), 1)
        XCTAssertEqual(ComputeDrift.number(1.5), "1.5")
        XCTAssertEqual(ComputeDrift.number(4), "4")
    }

    /// run_code reusing an older session says so.
    func testSendingCodeToAnOlderSessionSaysSo() async throws {
        sessions = FakeComputeSessions([.compute(id: "old", status: "Running", image: "images.canfar.net/p/compute:0")])
        let drift = try await service().submit(request(), by: .agent)
        XCTAssertEqual(drift?.differences.first, "runs images.canfar.net/p/compute:0, not \(image)")
        sessions = FakeComputeSessions([.compute(id: "same", status: "Running")])
        let none = try await service().submit(request("r2"), by: .agent)
        XCTAssertNil(none)
    }

    // MARK: - The session

    func testASessionIsReusedOrLaunchedWithTheRegistryCredentials() async throws {
        let compute = service()
        let first = try await compute.ensureSession()
        XCTAssertEqual(first, .launched(cores: 2, ram: 8))
        XCTAssertEqual(sessions.launched.map(\.image), [image])
        XCTAssertEqual(sessions.launched.first?.cores, 2)
        XCTAssertEqual(sessions.launched.first?.registryUsername, "robot")
        XCTAssertEqual(files.folders, [".verbinal", ".verbinal/exec", ".verbinal/exec/inbox", ".verbinal/exec/out"])
        let again = try await compute.ensureSession()
        XCTAssertTrue(again.reusedExisting, "a starting session is reused, not launched beside")
        XCTAssertEqual(sessions.launched.count, 1)

        let stopped = try await compute.stop()
        XCTAssertTrue(stopped)
        XCTAssertEqual(sessions.deleted, ["launched-1"])
        let stoppedAgain = try await compute.stop()
        XCTAssertFalse(stoppedAgain, "nothing left to stop")
    }

    /// Plan 19 S3 (QA N18): kept a 1-core session and said "4 cores / 8 GB".
    func testKeepingARunningSessionSaysTheSizeItHas() async throws {
        sessions = FakeComputeSessions([.compute(id: "small", status: "Running", image: image, ram: "1.07G", cores: "1")])
        let start = try await service().ensureSession(.init(image: image, cores: 4, ram: 8))
        guard case .reused(let cores, let memory, let drift) = start else { return XCTFail("\(start)") }
        XCTAssertEqual([cores, memory], ["1", "1.07G"])
        XCTAssertNotNil(drift)
        XCTAssertTrue(start.sentence.hasPrefix("Kept the verbinal-compute session already running, which has 1 core and 1.07 GB."),
                      start.sentence)
        XCTAssertTrue(start.sentence.contains("of the 4 cores"), start.sentence)
        XCTAssertTrue(sessions.launched.isEmpty)
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

    /// Plan 30 K: a run whose watching stopped — a sign-out, a quit — never
    /// stays running. After sign-in, one with time left is watched again; one
    /// past it is read once, and closed as noResult when nothing came back.
    func testARunNoOneWatchedIsLookedAtAgain() async throws {
        let store = ComputeRunStore(persistence: nil)
        let long = Date().addingTimeInterval(-3 * 24 * 3600)
        store.add(ComputeRun(request("lost", timeout: 480), author: .agent, submittedAt: long))
        store.add(ComputeRun(request("landed", timeout: 480), author: .agent, submittedAt: long))
        store.add(ComputeRun(request("fresh", timeout: 60), author: .user))
        files.put(RunCodeContract.outPath(id: "landed"), #"{"status":"ok","exit_code":0}"#)
        let compute = RemoteComputeService(
            runs: store, sessions: sessions, files: files,
            username: { [user] in user }, configuration: { [image] in .init(image: image, cores: 2, ram: 8) },
            registryAuth: { nil }, pollInterval: .milliseconds(10), tasks: TaskRegistry())

        await compute.resumeWatching()
        XCTAssertEqual(store.find("lost")?.state, ComputeRun.noResult, "nothing came back: closed, not running")
        XCTAssertEqual(store.find("landed")?.state, "ok", "its result came while no one watched: read")
        XCTAssertEqual(store.find("fresh")?.state, ComputeRun.running, "time left: watched again")

        files.put(RunCodeContract.outPath(id: "fresh"), #"{"status":"ok"}"#)
        for _ in 0..<100 where store.find("fresh")?.isFinished == false { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.find("fresh")?.state, "ok")
    }

    /// A compute session CANFAR cannot pull the image of is not ready, and
    /// says why — not "starting" for good — and no code is sent to it
    /// (handout 31: ImagePullBackOff for 17 minutes).
    func testASessionWhoseImageCannotBePulledIsNotReady() async throws {
        sessions = FakeComputeSessions([.compute(id: "c1", status: "Pending", image: "images.canfar.net/private-test/x:1")])
        let compute = service()
        sessions.events["c1"] = "Normal Scheduled assigned\nWarning Failed Failed to pull image\nWarning Failed Error: ImagePullBackOff"
        let stuck = try await compute.snapshot()
        XCTAssertEqual(stuck.state, .notReady)
        XCTAssertTrue(stuck.problem?.contains("cannot pull the compute image images.canfar.net/private-test/x:1") == true, stuck.problem ?? "")
        XCTAssertTrue(stuck.state.canStop)
        XCTAssertFalse(stuck.state.canRun(configured: true))
        do {
            try await compute.submit(request("r9"), by: .agent)
            XCTFail("code went to a session that cannot start")
        } catch let error as RemoteComputeError {
            guard case .notReady = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(files.uploads.isEmpty, "nothing dropped in its inbox")

        sessions.events["c1"] = "Normal Scheduled assigned\nNormal Pulling image"
        let starting = try await compute.snapshot()
        XCTAssertEqual(starting.state, .starting, "still pulling: it may start")
        XCTAssertNil(starting.problem)
    }
}
