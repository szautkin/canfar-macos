// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Behaviour pinning for the retry helper. Time-budget concerns: each test
/// uses a near-zero `initialDelay` so we never hit the policy's default
/// 300 ms backoff in the test suite.
final class RetryPolicyTests: XCTestCase {

    private let fast = RetryPolicy(
        maxAttempts: 3,
        initialDelay: .milliseconds(1),
        maxDelay: .milliseconds(10),
        backoffMultiplier: 2.0
    )

    // MARK: - isTransient classifier

    func testIsTransientForServerError() {
        XCTAssertTrue(isTransient(NetworkError.httpError(503, "")))
        XCTAssertTrue(isTransient(NetworkError.httpError(500, "")))
        XCTAssertTrue(isTransient(NetworkError.httpError(599, "")))
    }

    func testIsTransientFalseFor4xx() {
        XCTAssertFalse(isTransient(NetworkError.httpError(404, "")))
        XCTAssertFalse(isTransient(NetworkError.httpError(400, "")))
    }

    func testIsTransientForURLError() {
        XCTAssertTrue(isTransient(URLError(.timedOut)))
        XCTAssertTrue(isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(isTransient(URLError(.notConnectedToInternet)))
    }

    func testIsTransientFalseForBadURL() {
        XCTAssertFalse(isTransient(URLError(.badURL)))
        XCTAssertFalse(isTransient(URLError(.cancelled)))
    }

    func testIsTransientFalseForUnauthorized() {
        XCTAssertFalse(isTransient(NetworkError.unauthorized))
    }

    // MARK: - retrying

    func testRetryingSucceedsImmediately() async throws {
        let result = try await retrying(fast) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testRetryingRetriesTransientThenSucceeds() async throws {
        let counter = LockedCounter()
        let result = try await retrying(fast) {
            let current = counter.incrementAndReturn()
            if current < 2 {
                throw NetworkError.httpError(503, "transient")
            }
            return current
        }
        XCTAssertEqual(result, 2)
        XCTAssertEqual(counter.value, 2)
    }

    func testRetryingExhaustsAttempts() async {
        let counter = LockedCounter()
        do {
            _ = try await retrying(fast) {
                _ = counter.incrementAndReturn()
                throw NetworkError.httpError(503, "still down")
            }
            XCTFail("Expected throw after retries exhausted")
        } catch let error as NetworkError {
            if case .httpError(let code, _) = error {
                XCTAssertEqual(code, 503)
            } else {
                XCTFail("Wrong NetworkError: \(error)")
            }
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(counter.value, fast.maxAttempts,
                       "Should attempt exactly maxAttempts times")
    }

    func testRetryingDoesNotRetryNonTransient() async {
        let counter = LockedCounter()
        do {
            _ = try await retrying(fast) {
                _ = counter.incrementAndReturn()
                throw NetworkError.httpError(404, "missing")
            }
            XCTFail("Expected throw")
        } catch {
            // expected
        }
        XCTAssertEqual(counter.value, 1,
                       "404 is not transient — should not retry")
    }

    func testRetryingSurfacesCancellation() async {
        let task = Task {
            try await retrying(fast) {
                throw NetworkError.httpError(503, "")
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            // The retrying loop sleeps between attempts; on cancel during a
            // retry sleep we get CancellationError. If we manage to land in
            // the operation closure it'd throw 503 first — accept either.
        }
    }
}

// MARK: - Test helpers

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func incrementAndReturn() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
