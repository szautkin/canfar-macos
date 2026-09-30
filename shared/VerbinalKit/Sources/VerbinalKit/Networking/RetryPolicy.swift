// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Generic retry-with-backoff helper for transient network failures.
///
/// CADC services occasionally return 503 (load balancer / temporary
/// unavailable), and Wi-Fi → Ethernet transitions surface as
/// `URLError.networkConnectionLost`/`.timedOut` mid-request. A single retry
/// with a short backoff resolves the vast majority of these without the user
/// noticing. Callers that need finer-grained control (e.g., user-cancellable
/// long-running downloads) should keep their own retry loop.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var maxDelay: Duration
    /// Multiplier applied to the delay between attempts.
    public var backoffMultiplier: Double
    /// Wall-clock budget across ALL attempts (including the requests
    /// themselves, not just the backoff sleeps). Once elapsed time
    /// exceeds this, the last error is rethrown instead of retrying —
    /// attempt-count caps alone let a host that accepts-then-stalls
    /// burn `maxAttempts × timeoutInterval` (3 × 120s on the TAP path)
    /// while holding the caller. `nil` = attempts-only (legacy).
    public var overallBudget: Duration?
    /// Whether a request that timed out is tried again. Not for requests
    /// that wait minutes: a host that gave no answer in two is down, and a
    /// TAP search on a dead CADC held its spinner four minutes (plan 21 D5).
    public var retriesTimeouts: Bool

    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(300),
        maxDelay: Duration = .seconds(5),
        backoffMultiplier: Double = 2.0,
        overallBudget: Duration? = .seconds(180),
        retriesTimeouts: Bool = true
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.overallBudget = overallBudget
        self.retriesTimeouts = retriesTimeouts
    }

    /// Conservative default for short-lived metadata calls.
    public static let `default` = RetryPolicy()

    /// No retries. Use for user-facing actions where a single failure should
    /// surface immediately (e.g., login).
    public static let none = RetryPolicy(maxAttempts: 1)

    /// For requests allowed minutes (a TAP query): a dropped connection or
    /// a 5xx is tried again, a timeout is not.
    public static let longRequests = RetryPolicy(retriesTimeouts: false)

    /// Next backoff delay after `current`: exponential scaling by
    /// `backoffMultiplier`, clamped to `maxDelay` and floored at zero.
    ///
    /// Extracted from the `retrying` loop so the backoff math (multiplier
    /// scaling, clamping, and the `Duration` ↔ `Double` conversion) is
    /// directly unit-testable without timing-sensitive sleeps.
    func nextDelay(after current: Duration) -> Duration {
        let scaled = current.timeInSeconds * backoffMultiplier
        // A negative multiplier (or precision underflow) must never produce a
        // negative sleep interval.
        let next = Duration.seconds(max(0, scaled))
        return next > maxDelay ? maxDelay : next
    }
}

/// Decide whether a given error should trigger a retry.
///
/// Conservative by default — only NetworkErrors with 5xx status, transient
/// `URLError` codes, and obvious network drops. 4xx (client error) is *not*
/// retried because the request itself is wrong; retrying won't fix it.
@inlinable
public func isTransient(_ error: Error) -> Bool {
    if let netErr = error as? NetworkError {
        switch netErr {
        case .httpError(let code, _) where code >= 500 && code < 600:
            return true
        case .invalidResponse:
            return true
        case .invalidURL, .unauthorized:
            return false
        default:
            return false
        }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotConnectToHost, .cannotFindHost:
            return true
        default:
            return false
        }
    }
    return false
}

/// Execute `operation`, retrying on transient errors per `policy`.
///
/// On the final attempt, the error is rethrown rather than swallowed.
/// Sleep delays are cancellable: if the surrounding `Task` is cancelled we
/// throw `CancellationError` immediately rather than waiting out the backoff.
public func retrying<T: Sendable>(
    _ policy: RetryPolicy = .default,
    decisions: DecisionLog = .shared,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 0
    var delay = policy.initialDelay
    let started = ContinuousClock.now
    // Each decision says its rule, and names the request's service when the
    // work has a trace (plan 23 A).
    func decide(_ rule: Decision.Rule, _ error: Error, _ why: String) {
        let service = RequestTrace.current?.records.last(where: \.isFinished)?.service.name ?? "the request"
        decisions.record(rule, "\(service) \(RequestOutcome(error: error).meaning); \(why)")
    }
    while true {
        attempt += 1
        do {
            return try await operation()
        } catch {
            // Don't retry on cancellation — the caller meant for us to stop.
            if error is CancellationError { throw error }
            guard isTransient(error) else { throw error }
            if attempt >= policy.maxAttempts {
                decide(.notRetried, error, "not asked again: \(attempt) attempts made")
                throw error
            }
            if !policy.retriesTimeouts, (error as? URLError)?.code == .timedOut {
                decide(.notRetried, error, "not asked again: a request that timed out would wait its whole timeout again")
                throw error
            }
            // Wall-clock budget: give up rather than start an attempt
            // that would push total time past the ceiling.
            if let budget = policy.overallBudget,
               ContinuousClock.now - started + delay >= budget {
                decide(.notRetried, error, "not asked again: the time allowed for it is spent")
                throw error
            }
            decide(.retried, error, "asked again in \(delay.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))), attempt \(attempt + 1) of \(policy.maxAttempts)")
            try await Task.sleep(for: delay)
            // Exponential backoff, clamped to maxDelay.
            delay = policy.nextDelay(after: delay)
        }
    }
}

extension Duration {
    /// Total duration in seconds as a `Double`. Used for backoff scaling
    /// because `Duration` doesn't expose multiplication by a non-integer
    /// scalar directly. `internal` (not `private`) so the conversion is
    /// unit-testable for fractional / sub-second precision.
    var timeInSeconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
