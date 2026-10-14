// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 38 P0: the vocabulary every area's state is written in — written
/// once, tested once.
@MainActor
final class StateVocabularyTests: XCTestCase {

    // MARK: - Phase

    func testAResultIsKeptOnlyWhileItsTryIsTheNewest() {
        var phase = Phase<[String]>.idle
        let first = phase.begin()
        let second = phase.begin()
        XCTAssertFalse(phase.finish(first, with: .success(["old"])), "a superseded try's result is dropped")
        XCTAssertTrue(phase.isWorking)
        XCTAssertTrue(phase.finish(second, with: .success(["new"])))
        XCTAssertEqual(phase, .ready(["new"]))
        XCTAssertFalse(phase.finish(second, with: .success(["again"])), "a try ends once")
    }

    func testTheLastGoodValueStaysThroughARefreshAndAFailure() {
        var phase = Phase<[String]>.ready(["M31"])
        let attempt = phase.begin()
        XCTAssertEqual(phase.value, ["M31"], "still shown while it reloads")
        phase.finish(attempt, with: .failure(URLError(.notConnectedToInternet)))
        XCTAssertEqual(phase.value, ["M31"], "still shown after it failed")
        XCTAssertEqual(phase.problem?.kind, .offline)
        XCTAssertEqual(phase.dataState(isEmpty: \.isEmpty), .content, "the content, with the problem above it")
    }

    func testACancelledTryLeavesWhatWasThere() {
        var phase = Phase<Int>.ready(1)
        let attempt = phase.begin()
        phase.finish(attempt, with: .failure(CancellationError()))
        XCTAssertEqual(phase, .ready(1))
        var fresh = Phase<Int>.idle
        let first = fresh.begin()
        fresh.finish(first, with: .failure(CancellationError()))
        XCTAssertEqual(fresh, .idle)
    }

    func testHowAScreenShowsEachPhase() {
        XCTAssertEqual(Phase<[Int]>.idle.dataState(isEmpty: \.isEmpty), .loading)
        XCTAssertEqual(Phase<[Int]>.working(Attempt(), last: nil).dataState(isEmpty: \.isEmpty), .loading)
        XCTAssertEqual(Phase<[Int]>.ready([]).dataState(isEmpty: \.isEmpty), .empty)
        XCTAssertEqual(Phase<[Int]>.ready([1]).dataState(isEmpty: \.isEmpty), .content)
        XCTAssertEqual(Phase<[Int]>.failed(Problem(.other, "x"), last: nil).dataState(isEmpty: \.isEmpty), .error)
        XCTAssertEqual(Phase<[Int]>.ready([1]).stateName, "ready")
    }

    // MARK: - Problem

    func testEachErrorIsReadAsOneKindOfProblem() {
        XCTAssertEqual(Problem(NetworkError.unauthorized).kind, .signInRequired)
        XCTAssertFalse(Problem(NetworkError.unauthorized).retry, "signing in, not trying again, helps")
        XCTAssertEqual(Problem(NetworkError.httpError(404, "")).kind, .notFound)
        XCTAssertEqual(Problem(NetworkError.httpError(403, "")).kind, .refused)
        XCTAssertEqual(Problem(NetworkError.httpError(500, "boom")).kind, .other)
        XCTAssertTrue(Problem(NetworkError.httpError(500, "boom")).retry)
        XCTAssertEqual(Problem(URLError(.timedOut)).kind, .offline)
        XCTAssertEqual(Problem(URLError(.cancelled)).kind, .cancelled)
        XCTAssertEqual(Problem(CancellationError()).kind, .cancelled)
        XCTAssertEqual(Problem(Problem(.refused, "no")), Problem(.refused, "no"))
    }

    // MARK: - PhaseOwner

    final class Loader: PhaseOwner {
        var phase = Phase<String>.idle
    }

    func testOfTwoLoadsUnderWayTheNewestWins() async {
        let loader = Loader()
        let gate = AsyncStream<Void>.makeStream()
        async let slow = loader.run(\.phase) {
            for await _ in gate.stream { break }
            return "slow"
        }
        try? await Task.sleep(for: .milliseconds(20))
        let fastKept = await loader.run(\.phase) { "fast" }
        gate.continuation.yield()
        let slowKept = await slow
        XCTAssertTrue(fastKept)
        XCTAssertFalse(slowKept, "the older load came back late and was dropped")
        XCTAssertEqual(loader.phase, .ready("fast"))
    }

    // MARK: - Machine

    /// A door: the smallest machine with a refused event.
    enum Door: StateMachine {
        enum State: Equatable, Sendable { case closed, open, locked }
        enum Event: Sendable { case open, close, lock, unlock }
        static func next(_ state: State, on event: Event) -> State? {
            switch (state, event) {
            case (.closed, .open): .open
            case (.open, .close): .closed
            case (.closed, .lock): .locked
            case (.locked, .unlock): .closed
            default: nil
            }
        }
    }

    func testAMachineMovesOnlyWhereAnEventMeansSomething() {
        let door = Machine<Door>(.closed)
        XCTAssertTrue(door.send(.lock))
        XCTAssertFalse(door.send(.open), "a locked door does not open")
        XCTAssertEqual(door.state, .locked)
        XCTAssertEqual(door.refusals, 1)
        XCTAssertTrue(door.send(.unlock))
        XCTAssertTrue(door.send(.open))
        XCTAssertEqual(door.state, .open)
    }

    func testAToolWaitsForAStateInsteadOfPolling() async {
        let door = Machine<Door>(.closed)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            door.send(.open)
        }
        let opened = await door.until({ $0 == .open }, timeout: .seconds(2))
        XCTAssertEqual(opened, .open)
        let still = await door.until({ $0 == .locked }, timeout: .milliseconds(50))
        XCTAssertEqual(still, .open, "after the wait, the state as it is")
    }

    // MARK: - A viewer tab's document (P1b)

    func testADocumentMovesOnlyAsAnOpenCan() {
        let document = Machine<DocumentMachine>(.empty)
        XCTAssertFalse(document.send(.opened), "nothing was opening")
        XCTAssertTrue(document.send(.begin))
        XCTAssertTrue(document.send(.stage("Reading the header")))
        XCTAssertEqual(document.state, .opening(stage: "Reading the header", progress: nil))
        XCTAssertTrue(document.send(.opened))
        XCTAssertTrue(document.state.isOpen)
        XCTAssertFalse(document.send(.stage("late")), "a stage after it opened is refused")
        XCTAssertTrue(document.send(.failed(Problem(.other, "bad extension"))), "an open document can fail: an HDU that will not read")
        XCTAssertEqual(document.state.problem?.message, "bad extension")
        XCTAssertEqual(document.state.stateName, "failed")
        XCTAssertTrue(document.send(.begin), "Retry")
        XCTAssertTrue(document.send(.close))
        XCTAssertEqual(document.state, .empty)
    }
}
