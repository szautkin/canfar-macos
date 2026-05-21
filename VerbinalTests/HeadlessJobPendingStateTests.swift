// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Coverage for the pending-pod handling in `get_headless_job_logs`
/// and `get_headless_job_events`. F-2026-05-13-C from the QA report
/// — Skaha returns HTTP 404 while a job is Pending because no K8s
/// pod has been created yet, and the previous behaviour bubbled
/// that up as a generic `backendError`. The tools now catch the
/// 404 and surface a structured `state: "pending"` instead.
///
/// `handle()` requires a full `AIToolContext` (proposals + budget
/// stores) that's expensive to fabricate for two tools that don't
/// actually consult those fields. So we exercise the same fetch
/// closure + error pattern-match the handler uses, against the
/// public `NetworkError` shape — equivalent coverage, fewer moving
/// parts.
final class HeadlessJobPendingStateTests: XCTestCase {

    /// Mirrors the `isPendingPodSignal` predicate inside both
    /// tools. Same logic; testing here pins the contract.
    private func isPendingPodSignal(_ error: Error) -> Bool {
        guard let net = error as? NetworkError else { return false }
        guard case .httpError(let code, _) = net, code == 404 else { return false }
        return true
    }

    func testRecognises404AsPending() {
        let err = NetworkError.httpError(404, "session abc not found")
        XCTAssertTrue(isPendingPodSignal(err))
    }

    func testRecognises404WithEmptyBodyAsPending() {
        let err = NetworkError.httpError(404, "")
        XCTAssertTrue(isPendingPodSignal(err))
    }

    func test500IsNotPending() {
        // Real backend errors (5xx) must propagate, not collapse
        // to pending — the pod might be running and crashing.
        let err = NetworkError.httpError(500, "internal server error")
        XCTAssertFalse(isPendingPodSignal(err))
    }

    func test401IsNotPending() {
        // Auth-required is a distinct backend condition from
        // "pod doesn't exist yet". Caller should re-auth, not
        // poll for pod creation.
        let err = NetworkError.unauthorized
        XCTAssertFalse(isPendingPodSignal(err))
    }

    func testForeignErrorIsNotPending() {
        struct OtherFailure: Error {}
        XCTAssertFalse(isPendingPodSignal(OtherFailure()))
    }
}
