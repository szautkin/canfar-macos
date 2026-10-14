// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 004: `ObservationDetailModel.loadCAOM2()` must be retryable from any
/// `.failed(...)` state (not just `.failed("")`), and a no-op from in-flight /
/// terminal states. Uses an empty-publisherID row so `loadCAOM2()` fails fast
/// without touching the network.
@MainActor
final class ObservationDetailLoadStateTests: XCTestCase {

    private func makeModel() -> ObservationDetailModel {
        ObservationDetailModel(
            result: SearchResult(id: "obs", rawValues: [], searchIndex: []),
            columns: SearchResultColumns()
        )
    }

    /// Plan 38: the record's load is a Phase; whether it may (re)start is
    /// whether trying again can help.
    func testMayLoadAcrossThePhases() {
        let model = makeModel()
        XCTAssertTrue(model.mayLoad, "never started")
        model.load = .failed(Problem(.other, "any message"), last: nil)
        XCTAssertTrue(model.mayLoad)
        model.load = .working(Attempt(), last: nil)
        XCTAssertFalse(model.mayLoad)
        model.load = .failed(Problem(.signInRequired, "sign in", retry: false), last: nil)
        XCTAssertFalse(model.mayLoad)
        model.load = .failed(Problem(.notFound, "gone", retry: false), last: nil)
        XCTAssertFalse(model.mayLoad)
    }

    func testRetryAfterRealFailureReentersLoad() async {
        let model = makeModel()
        // Empty publisherID -> fast-fail with a non-empty message.
        await model.loadCAOM2()
        let firstMessage = model.load.problem?.message ?? ""
        XCTAssertFalse(firstMessage.isEmpty)

        // A real prior failure, then a retry: it re-runs the load.
        model.load = .failed(Problem(.other, "network blip"), last: nil)
        await model.loadCAOM2()
        XCTAssertEqual(model.load.problem?.message, firstMessage,
                       "retry should re-run the load, not stay stuck on the old failure")
    }

    func testNoOpWhileLoading() async {
        let model = makeModel()
        model.load = .working(Attempt(), last: nil)
        await model.loadCAOM2()
        XCTAssertEqual(model.load.stateName, "working", "a load in progress must not be restarted")
    }

    func testTerminalProblemsAreNotRetried() async {
        for problem in [Problem(.signInRequired, "sign in", retry: false), Problem(.notFound, "gone", retry: false)] {
            let model = makeModel()
            model.load = .failed(problem, last: nil)
            await model.loadCAOM2()
            XCTAssertEqual(model.load.problem, problem, "\(problem.kind) must be terminal (no retry)")
        }
    }
}
