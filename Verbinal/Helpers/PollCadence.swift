// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// How often the app asks CANFAR what changed.
///
/// Every session and batch-job notification is a side effect of a poll, so
/// the poll interval is the notification delay: at a flat 15 s or 45 s a
/// session came up, or a job failed, well before anyone heard, and a job
/// that started and failed inside one interval was never seen running at
/// all. Polling flat out is no answer either — a job can run for hours on a
/// shared platform.
///
/// So the cadence follows the evidence (as Verbinal for Windows does): just
/// changed → ask again soon; poll after poll of nothing → double the wait
/// up to a per-surface ceiling; nothing in flight at all → the idle
/// interval, still polling because work can start from another machine.
/// Each ceiling is at most the interval that surface used to run at, so no
/// notification arrives later than before.
struct PollCadence: Equatable {
    /// The quickest the app asks; the poll right after a change.
    static let busySeconds = 5
    /// Ceiling for the session strip while a session is pending — a short
    /// window someone is usually watching.
    static let sessionWatchSeconds = 8
    /// Ceiling for batch jobs while one is unfinished (was a flat 45 s).
    static let jobsWatchSeconds = 20
    /// Nothing in flight: no transition to report.
    static let idleSeconds = 45

    private let watchCeiling: Int
    /// Seconds to wait before the next poll.
    private(set) var seconds: Int

    /// Starts quick: the first poll is what finds out whether anything is
    /// in flight — typically right after the person launched something.
    init(watchCeiling: Int) {
        self.watchCeiling = watchCeiling
        seconds = min(Self.busySeconds, watchCeiling)
    }

    /// Folds in what the poll just saw.
    /// - Parameters:
    ///   - inFlight: can anything still change state?
    ///   - changed: did anything move since the last poll?
    mutating func observe(inFlight: Bool, changed: Bool) {
        seconds = !inFlight ? Self.idleSeconds
            : changed ? min(Self.busySeconds, watchCeiling)
            : min(seconds * 2, watchCeiling)
    }

    /// Waits `seconds`, reporting the seconds left (for "Auto-refresh 5s").
    /// - Returns: false when the task was cancelled.
    @MainActor
    func countdown(_ tick: (Int) -> Void) async -> Bool {
        for left in stride(from: seconds, to: 0, by: -1) {
            tick(left)
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        tick(0)
        return !Task.isCancelled
    }
}

/// A model that polls CANFAR at a ``PollCadence``.
@MainActor
protocol CadencedPoller: AnyObject {
    var cadence: PollCadence { get }
    /// Seconds to the next poll, for "Auto-refresh 5s".
    var pollCountdown: Int { get set }
    func poll() async
}

extension CadencedPoller {
    /// Polls until the task is cancelled or the poller is released. The
    /// poller is held only while a poll runs, never across the wait, so a
    /// model that goes away (the Portal after sign-out) stops polling
    /// instead of being kept alive by its own loop.
    func startPollLoop() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.cadence else { return }
                let waited = await wait.countdown { [weak self] in self?.pollCountdown = $0 }
                guard waited, let self else { return }
                await self.poll()
            }
        }
    }
}
