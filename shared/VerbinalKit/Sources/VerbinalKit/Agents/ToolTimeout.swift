// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Run a read-tool's `handle` body with a wall-clock deadline. If
/// `seconds` elapses before `work` returns, cancel the inner task
/// and throw `ToolFailureReason.backendError("<label> exceeded
/// <seconds>s …")`.
///
/// **Why this exists.** The 2026-05-15 QA report named `list_headless_jobs`
/// as locking up "at least four times across the session, each time
/// for 4+ minutes before timing out." `URLSession`'s configured
/// timeout doesn't reliably fire when the underlying connection is
/// in a half-open / TLS-stalled state, and the MCP read-tool surface
/// previously had no upper bound of its own — an MCP client could
/// sit blocked for `URLSession`'s 60s default *plus* however long
/// the system takes to give up. This primitive establishes a
/// per-tool ceiling so the agent always sees a recognisable
/// `backendError` within `seconds` and can decide to retry or move
/// on.
///
/// Mirrors `withApplierTimeout` for write appliers; the two are
/// kept structurally parallel so the read/write halves of the MCP
/// surface have the same liveness guarantee.
///
/// `seconds` is chosen per-tool via `JSONReadTool.toolTimeoutSeconds`
/// — the default is 60s, fast list ops drop to 30s, slow TAP queries
/// extend to 90–120s. Conservative bound; not a polling interval.
public func withToolTimeout<T: Sendable>(
    seconds: TimeInterval,
    label: String,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await work()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ToolFailureReason.backendError(
                "\(label) exceeded \(Int(seconds))s deadline — the upstream service may still be processing. Retry after a short pause if you need the data; the cluster state is unaffected."
            )
        }
        defer { group.cancelAll() }
        // First child to finish wins. If it's the timeout task, the
        // throw propagates out of `next()` immediately and the
        // `defer` cancels the in-flight `work`. If it's the work
        // task, we get the success value; `defer` cancels the
        // already-finished sleep harmlessly.
        guard let result = try await group.next() else {
            throw ToolFailureReason.backendError("\(label) task group produced no result")
        }
        return result
    }
}
