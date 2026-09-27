// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class PollCadenceTests: XCTestCase {

    func testStartsQuickSoAFreshLaunchIsSeenSoon() {
        XCTAssertEqual(PollCadence(watchCeiling: PollCadence.jobsWatchSeconds).seconds, 5)
    }

    func testEasesOffDoublingToTheCeilingWhileNothingMoves() {
        var cadence = PollCadence(watchCeiling: PollCadence.jobsWatchSeconds)
        var seen: [Int] = []
        for _ in 0..<4 {
            cadence.observe(inFlight: true, changed: false)
            seen.append(cadence.seconds)
        }
        XCTAssertEqual(seen, [10, 20, 20, 20])
    }

    func testAChangeSnapsBackToBusy() {
        var cadence = PollCadence(watchCeiling: PollCadence.jobsWatchSeconds)
        cadence.observe(inFlight: true, changed: false)
        cadence.observe(inFlight: true, changed: false)
        cadence.observe(inFlight: true, changed: true)
        XCTAssertEqual(cadence.seconds, PollCadence.busySeconds)
    }

    func testNothingInFlightIdles() {
        var cadence = PollCadence(watchCeiling: PollCadence.sessionWatchSeconds)
        cadence.observe(inFlight: false, changed: true)
        XCTAssertEqual(cadence.seconds, PollCadence.idleSeconds)
    }

    /// No surface is ever slower than it used to be while work is in flight.
    func testCeilingsNeverExceedTheOldFixedIntervals() {
        XCTAssertLessThanOrEqual(PollCadence.sessionWatchSeconds, 15)
        XCTAssertLessThanOrEqual(PollCadence.jobsWatchSeconds, 45)
        var sessions = PollCadence(watchCeiling: PollCadence.sessionWatchSeconds)
        for _ in 0..<10 { sessions.observe(inFlight: true, changed: false) }
        XCTAssertEqual(sessions.seconds, PollCadence.sessionWatchSeconds)
    }
}

@MainActor
final class CadencedPollerTests: XCTestCase {

    private final class Probe: CadencedPoller {
        let cadence = PollCadence(watchCeiling: PollCadence.jobsWatchSeconds)
        var pollCountdown = 0
        func poll() async {}
    }

    /// The loop must not keep its model alive: the Portal's session list
    /// polled on after sign-out when its loop held it across the wait.
    func testAReleasedPollerIsNotKeptAliveByItsLoop() async throws {
        final class Watch { weak var probe: Probe? }
        var probe: Probe? = Probe()
        let watch = Watch()
        watch.probe = probe
        let loop = try XCTUnwrap(probe).startPollLoop()
        defer { loop.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(watch.probe?.pollCountdown ?? 0, 0, "the countdown is running")
        probe = nil
        XCTAssertNil(watch.probe, "released mid-wait, not held until the next poll")
    }
}

final class StatusTransitionsTests: XCTestCase {

    private struct Job { let id: String; let status: String }

    private func settled(_ t: StatusTransitions, _ jobs: [Job]) -> [String] {
        t.newlySettled(jobs, id: \.id,
                       wasInFlight: { $0 == "Running" || $0 == "Pending" },
                       isSettled: { $0.status == "Completed" || $0.status == "Failed" }).map(\.id)
    }

    func testTheFirstPollAnnouncesNothing() {
        let jobs = [Job(id: "a", status: "Failed")]
        let t = StatusTransitions(previous: nil, current: ["a": "Failed"])
        XCTAssertEqual(settled(t, jobs), [], "what failed before the app looked is not news")
        XCTAssertFalse(t.changed)
    }

    func testAJobThatWasRunningAndFinishedIsAnnounced() {
        let t = StatusTransitions(previous: ["a": "Running", "b": "Completed"], current: ["a": "Completed", "b": "Completed"])
        XCTAssertEqual(settled(t, [Job(id: "a", status: "Completed"), Job(id: "b", status: "Completed")]), ["a"])
        XCTAssertTrue(t.changed)
    }

    /// Started and failed inside one poll interval — never seen running.
    func testAJobThatAppearedAlreadyFailedIsAnnounced() {
        let t = StatusTransitions(previous: ["a": "Completed"], current: ["a": "Completed", "new": "Failed"])
        XCTAssertEqual(settled(t, [Job(id: "a", status: "Completed"), Job(id: "new", status: "Failed")]), ["new"])
    }

    func testNoMovementIsNoChange() {
        let t = StatusTransitions(previous: ["a": "Running"], current: ["a": "Running"])
        XCTAssertFalse(t.changed)
        XCTAssertEqual(settled(t, [Job(id: "a", status: "Running")]), [])
    }
}
