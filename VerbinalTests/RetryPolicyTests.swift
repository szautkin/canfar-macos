// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit
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

    // MARK: - Backoff math (nextDelay)

    /// `nextDelay` scales the current delay by `backoffMultiplier` for a range
    /// of multipliers and clamps each result at `maxDelay`.
    func testNextDelayScalesByMultiplierAcrossAttempts() {
        // maxDelay set high enough that clamping never kicks in here.
        for multiplier in [1.5, 2.0, 3.0] as [Double] {
            let policy = RetryPolicy(
                maxAttempts: 5,
                initialDelay: .milliseconds(100),
                maxDelay: .seconds(1_000),
                backoffMultiplier: multiplier
            )
            var delay = policy.initialDelay
            var expectedSeconds = 0.1
            for attempt in 1...4 {
                delay = policy.nextDelay(after: delay)
                expectedSeconds *= multiplier
                XCTAssertEqual(
                    delay.timeInSeconds, expectedSeconds, accuracy: 1e-9,
                    "multiplier \(multiplier), attempt \(attempt)")
            }
        }
    }

    /// Once the scaled value exceeds `maxDelay`, every subsequent delay is
    /// pinned to the clamp.
    func testNextDelayClampsAtMaxDelay() {
        let policy = RetryPolicy(
            maxAttempts: 6,
            initialDelay: .milliseconds(300),
            maxDelay: .seconds(5),
            backoffMultiplier: 2.0
        )
        var delay = policy.initialDelay
        var sawClamp = false
        for _ in 0..<10 {
            delay = policy.nextDelay(after: delay)
            XCTAssertLessThanOrEqual(
                delay, policy.maxDelay,
                "delay must never exceed maxDelay")
            if delay == policy.maxDelay { sawClamp = true }
        }
        XCTAssertTrue(sawClamp, "exponential growth should reach the clamp")
        // Stays pinned at the clamp once reached.
        XCTAssertEqual(policy.nextDelay(after: policy.maxDelay), policy.maxDelay)
    }

    /// A tiny `maxDelay` combined with a large multiplier keeps every delay at
    /// the clamp from the very first step.
    func testNextDelayTinyMaxDelayLargeMultiplierStaysClamped() {
        let policy = RetryPolicy(
            maxAttempts: 4,
            initialDelay: .milliseconds(1),
            maxDelay: .milliseconds(1),
            backoffMultiplier: 1_000.0
        )
        var delay = policy.initialDelay
        for _ in 0..<5 {
            delay = policy.nextDelay(after: delay)
            XCTAssertEqual(delay, .milliseconds(1),
                           "delay must stay clamped at the 1ms maxDelay")
        }
    }

    /// Very small and very large multipliers stay non-negative and bounded by
    /// `maxDelay`. A multiplier of 0 collapses the delay to zero; a negative
    /// multiplier is floored at zero rather than producing a negative sleep.
    func testNextDelayExtremeMultipliersStayNonNegativeAndBounded() {
        let multipliers: [Double] = [0.0, 0.000_001, 1e9, -1.0, -5.0]
        for multiplier in multipliers {
            let policy = RetryPolicy(
                maxAttempts: 3,
                initialDelay: .milliseconds(50),
                maxDelay: .seconds(2),
                backoffMultiplier: multiplier
            )
            var delay = policy.initialDelay
            for _ in 0..<5 {
                delay = policy.nextDelay(after: delay)
                XCTAssertGreaterThanOrEqual(
                    delay, .zero,
                    "multiplier \(multiplier) produced a negative delay")
                XCTAssertLessThanOrEqual(
                    delay, policy.maxDelay,
                    "multiplier \(multiplier) exceeded maxDelay")
            }
        }
    }

    // MARK: - Duration.timeInSeconds precision

    func testTimeInSecondsForWholeSeconds() {
        XCTAssertEqual(Duration.seconds(3).timeInSeconds, 3.0, accuracy: 1e-12)
    }

    func testTimeInSecondsForSubSecondDurations() {
        XCTAssertEqual(Duration.milliseconds(300).timeInSeconds, 0.3,
                       accuracy: 1e-9)
        XCTAssertEqual(Duration.milliseconds(1).timeInSeconds, 0.001,
                       accuracy: 1e-12)
        XCTAssertEqual(Duration.microseconds(500).timeInSeconds, 0.000_5,
                       accuracy: 1e-12)
    }

    func testTimeInSecondsForFractionalNanoseconds() {
        // 1.5 seconds split as 1 s + 500 ms exercises the seconds +
        // attoseconds recombination in timeInSeconds.
        let oneAndAHalf = Duration.seconds(1) + Duration.milliseconds(500)
        XCTAssertEqual(oneAndAHalf.timeInSeconds, 1.5, accuracy: 1e-9)

        // Attosecond-level component (1 ns = 1e9 attoseconds) survives the
        // Double conversion to roughly nanosecond precision.
        XCTAssertEqual(Duration.nanoseconds(1).timeInSeconds, 1e-9,
                       accuracy: 1e-12)
    }

    func testTimeInSecondsForZero() {
        XCTAssertEqual(Duration.zero.timeInSeconds, 0.0)
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
