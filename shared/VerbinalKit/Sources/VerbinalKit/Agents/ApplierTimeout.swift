// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Run `work` with a wall-clock deadline. If `seconds` elapses before
/// `work` returns, cancel the inner task and throw
/// `ProposalApplyError.backendError("<label> exceeded <seconds>s …")`.
///
/// **Why this exists.** `ProposalApplier.apply` is an open-ended
/// `async throws -> Void`. The framework dispatches it from
/// `AgentsService.applyProposal` with a single un-bounded `try await`.
/// If the applier hangs — URLSession stuck after the body arrived but
/// before the server responded, sandbox file-coordination deadlock,
/// any other "no signal" failure — the framework emits neither
/// `proposalApplied` nor `proposalRejected`. Observers (UI, MCP
/// clients, monitors) cannot distinguish "still working" from
/// "permanently stuck", which is the worst-shape failure mode the
/// 2026-05-13 QA finding F-2026-05-13-A flagged.
///
/// This primitive gives every applier the same bounded liveness
/// guarantee: either it returns within `seconds`, or it raises a
/// recognisable error that the dispatch path turns into
/// `proposalRejected`. The user sees a real outcome instead of an
/// invisible hang.
///
/// `seconds` should be chosen per-operation: a `vospace_mkdir` should
/// not need more than 30s, a 500 MB upload over a typical link can
/// reasonably want 10 min. Conservative bound; not a polling interval.
public func withApplierTimeout<T: Sendable>(
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
            throw ProposalApplyError.backendError(
                "\(label) exceeded \(Int(seconds))s deadline — operation may still be running app-side; check the in-app activity feed before retrying"
            )
        }
        defer { group.cancelAll() }
        // First child to finish wins. If it's the timeout task, the
        // throw propagates out of `next()` immediately and the
        // `defer` cancels the in-flight `work`. If it's the work
        // task, we get the success value; `defer` cancels the
        // already-finished sleep harmlessly.
        guard let result = try await group.next() else {
            throw ProposalApplyError.backendError("\(label) task group produced no result")
        }
        return result
    }
}
