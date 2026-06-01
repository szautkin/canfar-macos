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
    private typealias LoadState = ObservationDetailModel.LoadState

    private func makeModel() -> ObservationDetailModel {
        ObservationDetailModel(
            result: SearchResult(id: "obs", rawValues: [], searchIndex: []),
            columns: SearchResultColumns()
        )
    }

    func testIsRetryableAcrossAllStates() {
        XCTAssertTrue(LoadState.idle.isRetryable)
        XCTAssertTrue(LoadState.failed("any message").isRetryable)
        XCTAssertTrue(LoadState.failed("").isRetryable)
        XCTAssertFalse(LoadState.loading.isRetryable)
        XCTAssertFalse(LoadState.loaded.isRetryable)
        XCTAssertFalse(LoadState.authRequired.isRetryable)
        XCTAssertFalse(LoadState.notFound.isRetryable)
    }

    func testRetryAfterRealFailureReentersLoad() async {
        let model = makeModel()
        // Empty publisherID -> fast-fail with a non-empty message.
        await model.loadCAOM2()
        guard case .failed(let firstMessage) = model.loadState else {
            return XCTFail("expected .failed, got \(model.loadState)")
        }
        XCTAssertFalse(firstMessage.isEmpty)

        // Simulate a *real* (non-empty) prior failure, then retry. With the
        // old `loadState == .failed("")` guard this would NOT re-enter and
        // would stay at "network blip"; the fix re-runs the load.
        model.loadState = .failed("network blip")
        await model.loadCAOM2()
        guard case .failed(let secondMessage) = model.loadState else {
            return XCTFail("expected .failed after retry, got \(model.loadState)")
        }
        XCTAssertEqual(secondMessage, firstMessage,
                       "retry should re-run the load, not stay stuck on the old failure")
    }

    func testNoOpWhileLoading() async {
        let model = makeModel()
        model.loadState = .loading
        await model.loadCAOM2()
        XCTAssertEqual(model.loadState, .loading, "a load in progress must not be restarted")
    }

    func testTerminalStatesAreNotRetried() async {
        for terminal: LoadState in [.loaded, .authRequired, .notFound] {
            let model = makeModel()
            model.loadState = terminal
            await model.loadCAOM2()
            XCTAssertEqual(model.loadState, terminal, "\(terminal) must be terminal (no retry)")
        }
    }
}
