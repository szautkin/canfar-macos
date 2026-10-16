// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// The activity bar: every slow task has an outcome, even one nobody gave,
/// and the words say what is happening without becoming furniture.
@MainActor
final class ActivityTests: XCTestCase {

    private struct Refused: LocalizedError { var errorDescription: String? { "HTTP 400: image not found" } }

    // MARK: - The registry

    func testATaskEndsOnceWithTheFirstOutcomeAndItsStage() {
        let registry = TaskRegistry()
        let probe = registry.begin(.discovery, "Inspect skaha/base:1")
        probe.stage("Waiting for job abc")
        XCTAssertEqual(registry.runningCount, 1)
        XCTAssertEqual(registry.tasks[0].stage, "Waiting for job abc")
        probe.fail("the job failed")
        probe.succeed()
        XCTAssertEqual(registry.tasks[0].progress, .failed, "the first outcome wins")
        XCTAssertEqual(registry.tasks[0].message, "the job failed")
        XCTAssertEqual(registry.tasks[0].stage, "", "a finished task has no stage (plan 15 O4, QA L10)")
        XCTAssertEqual(registry.failedCount, 1)
        XCTAssertNotNil(registry.tasks[0].finished)
    }

    func testAHandleLetGoWithoutAnOutcomeIsAbandoned() async throws {
        let registry = TaskRegistry()
        do {
            _ = registry.begin(.storage, "Upload x.fits")
        }
        for _ in 0..<50 where registry.tasks.first?.isFinished != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(registry.tasks.first?.progress, .cancelled, "never 'running' for the rest of the session")
    }

    func testTrackingSaysHowTheWorkEnded() async {
        let registry = TaskRegistry()
        let value = await registry.track(.launch, "Launch notebook") { _ in 42 }
        XCTAssertEqual(value, 42)
        do {
            try await registry.track(.launch, "Launch desktop") { handle in
                await handle.stage("Asking the platform")
                throw Refused()
            }
            XCTFail("it throws")
        } catch {}
        do {
            try await registry.track(.download, "Download M31") { _ in throw CancellationError() }
        } catch {}
        XCTAssertEqual(registry.tasks.map(\.progress), [.succeeded, .failed, .cancelled])
        XCTAssertEqual(registry.tasks[1].message, "HTTP 400: image not found")
    }

    func testFinishedTasksMakeRoomButRunningOnesNeverDo() {
        let registry = TaskRegistry()
        let kept = registry.begin(.discovery, "the long one")
        var handles: [TaskHandle] = []
        for index in 0..<(TaskRegistry.maxTasks + 5) {
            let handle = registry.begin(.discovery, "probe \(index)")
            handle.succeed()
            handles.append(handle)
        }
        XCTAssertEqual(registry.tasks.count, TaskRegistry.maxTasks)
        XCTAssertEqual(registry.tasks.first?.label, "the long one")
        registry.clearFinished()
        XCTAssertEqual(registry.tasks.map(\.label), ["the long one"])
        kept.succeed()
    }

    // MARK: - The words

    private func task(_ label: String, _ progress: TaskProgress = .running, stage: String = "", message: String? = nil,
                      seconds: TimeInterval = 0) -> TrackedTask {
        let start = Date(timeIntervalSince1970: 1000)
        return TrackedTask(id: Int.random(in: 1...9999), kind: .storage, label: label, stage: stage, progress: progress,
                           message: message, started: start,
                           finished: progress == .running ? nil : start.addingTimeInterval(seconds))
    }

    func testTheLineNamesOneTaskAndCountsSeveral() {
        XCTAssertEqual(ActivitySummary.line([task("done", .succeeded)]), "Idle")
        XCTAssertEqual(ActivitySummary.line([task("Inspect x", stage: "Waiting for job 7")]), "Inspect x — Waiting for job 7")
        XCTAssertEqual(ActivitySummary.line([task("a"), task("b"), task("c", .failed)]), "2 tasks running")
        XCTAssertNil(ActivitySummary.failures([task("a"), task("b", .succeeded)]), "no permanent zero")
        XCTAssertEqual(ActivitySummary.failures([task("a", .failed), task("b", .cancelled)]), "2 failed")
    }

    func testARowGivesAFailuresReasonOrHowLongItTook() {
        let now = Date(timeIntervalSince1970: 1000 + 187)
        XCTAssertEqual(ActivitySummary.describe(task("x", .failed, message: "quota exceeded"), now: now).detail, "quota exceeded")
        XCTAssertEqual(ActivitySummary.describe(task("x", .failed), now: now).detail, "failed, no reason given")
        XCTAssertEqual(ActivitySummary.describe(task("x", .cancelled), now: now).detail, "abandoned before it finished")
        XCTAssertEqual(ActivitySummary.describe(task("x", .succeeded, message: "Deleted 3 items", seconds: 4), now: now).detail,
                       "Deleted 3 items · 4s")
        XCTAssertEqual(ActivitySummary.describe(task("x", stage: "Uploading"), now: now).detail, "Uploading · 3m 7s")
        XCTAssertEqual(ActivitySummary.lines([task("old", .succeeded), task("new")], now: now).map(\.title), ["new", "old"])
        XCTAssertEqual(ActivitySummary.duration(0.4), "just now")
        XCTAssertEqual(ActivitySummary.duration(3725), "1h 2m")
    }

    // MARK: - Where tasks come from, and list_activity

    func testARemoteRunIsOnTheBarUntilItsResultComes() async throws {
        let registry = TaskRegistry()
        let files = FakeComputeFiles()
        let compute = RemoteComputeService(
            runs: ComputeRunStore(persistence: nil), sessions: FakeComputeSessions(), files: files,
            username: { "me" }, configuration: { .init(image: "i:1", cores: 1, ram: 1) }, registryAuth: { nil },
            pollInterval: .milliseconds(10), tasks: registry)
        try await compute.submit(RunCodeContract.Request(id: "r", language: "python", code: "1", timeout_seconds: 5), by: .agent)
        XCTAssertEqual(registry.tasks.first?.stage, "Waiting for the result")
        XCTAssertEqual(registry.tasks.first?.kind, .compute, "a code run is its own kind (QA L10)")
        XCTAssertEqual(registry.tasks.first?.startedBy, .assistant, "said once, by who started it (plan 17 A1)")
        files.put(RunCodeContract.outPath(id: "r"), #"{"status":"timeout"}"#)
        for _ in 0..<100 where registry.runningCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(registry.tasks.first?.progress, .failed)
        XCTAssertEqual(registry.tasks.first?.message, "timeout")

        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        let tasks = registry.tasks
        guard case .data(let data) = await ListActivityTool(tasks: { tasks }).invoke(arguments: Data("{}".utf8), context: ctx) else {
            return XCTFail()
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["failed"] as? Int, 1)
        XCTAssertEqual((object["tasks"] as? [[String: Any]])?.first?["kind"] as? String, "compute")
    }

    // MARK: - How far it has got, and pausing (plan 40)

    func testACountShowsAtMostFourTimesASecondAndItsLastAlways() async throws {
        let registry = TaskRegistry()
        let sync = registry.begin(.storage, "Syncing with your storage")
        sync.count(1, of: 10)
        XCTAssertEqual(registry.tasks[0].done, 1)
        for done in 2...9 { sync.count(done, of: 10) }
        XCTAssertEqual(registry.tasks[0].done, 1, "not redrawn for every item")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(registry.tasks[0].done, 9, "the last count lands")
        sync.count(10, of: 10)
        XCTAssertEqual(registry.tasks[0].done, 10, "the end shows at once")
        XCTAssertEqual(registry.tasks[0].countText, "10 of 10")
        XCTAssertEqual(registry.tasks[0].fraction, 1)
    }

    func testAPausedTaskIsNeitherRunningNorFinishedAndItsOwnerIsTold() {
        let registry = TaskRegistry()
        var told: [String] = []
        let sync = registry.begin(.storage, "Syncing with your storage", pausing: .init(
            pause: { told.append("pause \($0.rawValue)") }, resume: { told.append("resume \($0.rawValue)") }))
        XCTAssertTrue(registry.tasks[0].canPause)
        XCTAssertNil(registry.pause(sync.id, by: .assistant, why: "the person is on a slow network"))
        XCTAssertEqual(registry.tasks[0].progress, .paused)
        XCTAssertEqual(registry.tasks[0].pause?.by, .assistant)
        XCTAssertEqual(registry.tasks[0].pause?.cause.why, "the person is on a slow network")
        XCTAssertEqual(registry.runningCount, 0)
        XCTAssertEqual(registry.pausedCount, 1)
        XCTAssertFalse(registry.tasks[0].isFinished)
        registry.clearFinished()
        XCTAssertEqual(registry.tasks.count, 1, "Clear Finished leaves what is paused")
        XCTAssertNil(registry.pause(sync.id, by: .person), "paused already: nothing to do")
        XCTAssertNil(registry.resume(sync.id, by: .person))
        XCTAssertEqual(registry.tasks[0].progress, .running)
        XCTAssertEqual(registry.tasks[0].pause?.resumed, true)
        XCTAssertEqual(told, ["pause assistant", "resume person"])

        let probe = registry.begin(.discovery, "Inspect x")
        XCTAssertEqual(registry.pause(probe.id, by: .person), "Inspect x cannot be paused.")
        XCTAssertNotNil(registry.pause(999, by: .person))
        sync.succeed()
        XCTAssertEqual(registry.resume(sync.id, by: .person), "Syncing with your storage has finished (succeeded).")
        XCTAssertNil(registry.pausing(sync.id), "a finished task forgets how to pause")
    }

    func testWorkPausedBeforeBeginsPaused() {
        let registry = TaskRegistry()
        let mark = PauseMark(by: .person, cause: Cause(), at: Date(), resumed: false)
        _ = registry.begin(.storage, "Syncing with your storage", pausing: .init(pause: { _ in }, resume: { _ in }), pausedBy: mark)
        XCTAssertEqual(registry.tasks[0].progress, .paused)
        XCTAssertEqual(ActivitySummary.line(registry.tasks), "Syncing with your storage — paused")
    }

    func testTheWordsSayTheCountAndWhoPaused() {
        var sync = task("Syncing with your storage", stage: "Image package lists")
        sync.done = 120
        sync.total = 288
        XCTAssertEqual(ActivitySummary.line([sync]), "Syncing with your storage — Image package lists, 120 of 288")
        sync.progress = .paused
        sync.pause = PauseMark(by: .assistant, cause: Cause(), at: Date(), resumed: false)
        XCTAssertEqual(ActivitySummary.line([sync]), "Syncing with your storage — paused", "never Idle while something is paused")
        XCTAssertEqual(ActivitySummary.line([task("Inspect x"), sync]), "Inspect x · 1 paused")
        XCTAssertEqual(ActivitySummary.describe(sync).detail, "Paused by your assistant · Image package lists, 120 of 288")
        XCTAssertEqual(ActivitySummary.describe(sync).fraction, 120.0 / 288)
    }

    func testAnAssistantPausesAndResumesWithTheTools() async throws {
        let registry = TaskRegistry()
        var told: [Initiator] = []
        let sync = registry.begin(.storage, "Syncing with your storage", pausing: .init(
            pause: { told.append($0) }, resume: { told.append($0) }))
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        func call(_ tool: PauseActivityTool, _ args: String) async throws -> [String: Any] {
            let result = await Initiator.$current.withValue(.assistant) { await tool.invoke(arguments: Data(args.utf8), context: ctx) }
            guard case .data(let data) = result else { throw ToolFailureReason.invalidArgument("\(result)") }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let paused = try await call(.pause(registry: registry), #"{"id": \#(sync.id), "reason": "the person asked to stop syncing for now"}"#)
        let task = try XCTUnwrap(paused["task"] as? [String: Any])
        XCTAssertEqual(task["status"] as? String, "paused")
        XCTAssertEqual(task["pausedBy"] as? String, "assistant")
        XCTAssertEqual(task["pausedWhy"] as? String, "the person asked to stop syncing for now")
        _ = try await call(.resume(registry: registry), #"{"id": \#(sync.id)}"#)
        XCTAssertEqual(registry.tasks[0].progress, .running)
        XCTAssertEqual(told, [.assistant, .assistant])

        let unknown = await PauseActivityTool.pause(registry: registry).invoke(arguments: Data(#"{"id": 999}"#.utf8), context: ctx)
        guard case .failed(.unknownTarget) = unknown else { return XCTFail("\(unknown)") }
        let listed = await ListActivityTool(tasks: { await registry.tasks }).invoke(arguments: Data("{}".utf8), context: ctx)
        guard case .data(let data) = listed else { return XCTFail() }
        let entry = try XCTUnwrap(((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tasks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["id"] as? Int, sync.id)
        XCTAssertEqual(entry["pausable"] as? Bool, true)
    }

    /// The session log says who paused and resumed, why, and when — at
    /// the pause and the resume, not when the task began (plan 40; the
    /// live check had a resume half a minute late in the log's times).
    func testTheSessionLogSaysWhoPausedAndResumed() {
        let session = UUID()
        var sync = task("Syncing with your storage")
        sync.done = 120
        sync.total = 288
        sync.progress = .paused
        let pausedAt = sync.started.addingTimeInterval(40)
        sync.pause = PauseMark(by: .assistant, cause: Cause(why: "slow network", session: session), at: pausedAt, resumed: false)
        let seen = SessionViewpoint(session: session)
        let paused = SessionLogLine.task(sync, seen: seen)
        XCTAssertEqual(paused.line, "Paused: Syncing with your storage at 120 of 288 — by the assistant, because: slow network.")
        XCTAssertEqual(paused.at, pausedAt)
        sync.progress = .running
        let resumedAt = sync.started.addingTimeInterval(70)
        sync.pause = PauseMark(by: .person, cause: Cause(), at: resumedAt, resumed: true)
        let resumed = SessionLogLine.task(sync, seen: seen)
        XCTAssertEqual(resumed.line, "Resumed: Syncing with your storage — by the person.")
        XCTAssertEqual(resumed.at, resumedAt)
    }
}
