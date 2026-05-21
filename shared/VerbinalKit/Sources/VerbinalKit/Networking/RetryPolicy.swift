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

    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(300),
        maxDelay: Duration = .seconds(5),
        backoffMultiplier: Double = 2.0
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
    }

    /// Conservative default for short-lived metadata calls.
    public static let `default` = RetryPolicy()

    /// No retries. Use for user-facing actions where a single failure should
    /// surface immediately (e.g., login).
    public static let none = RetryPolicy(maxAttempts: 1)
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
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 0
    var delay = policy.initialDelay
    while true {
        attempt += 1
        do {
            return try await operation()
        } catch {
            // Don't retry on cancellation — the caller meant for us to stop.
            if error is CancellationError { throw error }
            if attempt >= policy.maxAttempts || !isTransient(error) {
                throw error
            }
            try await Task.sleep(for: delay)
            // Exponential backoff, clamped to maxDelay.
            let next = Duration.seconds(delay.timeInSeconds * policy.backoffMultiplier)
            delay = next > policy.maxDelay ? policy.maxDelay : next
        }
    }
}

private extension Duration {
    /// Total duration in seconds as a `Double`. Used for backoff scaling
    /// because `Duration` doesn't expose multiplication by a non-integer
    /// scalar directly.
    var timeInSeconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
