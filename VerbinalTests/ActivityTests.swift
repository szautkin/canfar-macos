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
}
