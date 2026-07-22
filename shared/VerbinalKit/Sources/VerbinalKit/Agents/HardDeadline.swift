// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One-shot claim gate: exactly one of N racers wins. Class (not actor)
/// because the losers must be able to check synchronously from any
/// executor without an await.
private final class DeadlineOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True exactly once, for the first caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Race `work` against a wall-clock deadline WITHOUT structured joining.
///
/// `withToolTimeout` / `withApplierTimeout` use a throwing task group,
/// and `withThrowingTaskGroup` implicitly awaits ALL children before
/// unwinding — `cancelAll()` only *requests* cancellation. Work that
/// isn't cancellation-responsive (a synchronous mmap fault on a stalled
/// volume, a tight CPU render loop) therefore holds the caller past the
/// "deadline", which is exactly how the MCP serve loop wedged for
/// minutes (2026-07-21 Mac QA, F5).
///
/// This primitive resumes the caller AT the deadline regardless: the
/// work task is cancelled and orphaned — it keeps running in the
/// background until it notices cancellation (or finishes), and its
/// result is discarded. Use only where an abandoned straggler is safe
/// (the router's dispatch backstop); prefer the structured helpers when
/// the work is known to be cancellation-responsive.
public func withHardDeadline<T: Sendable>(
    seconds: TimeInterval,
    onDeadline: @escaping @Sendable () -> T,
    work: @escaping @Sendable () async -> T
) async -> T {
    let once = DeadlineOnce()
    return await withCheckedContinuation { continuation in
        let workTask = Task {
            let value = await work()
            if once.claim() {
                continuation.resume(returning: value)
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() {
                workTask.cancel()
                continuation.resume(returning: onDeadline())
            }
        }
    }
}
