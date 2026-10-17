// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What kind of work it is, for the icon and for an agent's reading.
enum TaskKind: String, Codable, Sendable {
    /// Inspecting a container image.
    case discovery
    /// Launching a session or batch job.
    case launch
    /// Acting on an existing session.
    case session
    /// Running code on the compute session (Remote Compute, `run_code`).
    case compute
    /// Reading or writing Storage.
    case storage
    /// Fetching an observation's file, or a cutout of it.
    case download
    /// Keeping Research's records in order.
    case research
    /// An assistant's call still working past its answer (plan 30 L).
    case answer
}

/// Where a task got to.
enum TaskProgress: String, Codable, Sendable {
    case running
    /// Stopped where it was by someone who said so, until they resume it
    /// (plan 40). Neither running nor finished.
    case paused
    case succeeded
    /// Carries a reason — a failure without one is what this exists to stop.
    case failed
    /// It ended without anyone saying how: the work was abandoned.
    case cancelled
}

/// One piece of slow work, as the activity bar shows it.
struct TrackedTask: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: TaskKind
    let label: String
    /// The person, their assistant, or the app itself (plan 17 A1).
    var startedBy = Initiator.person
    /// Why, and what it belongs to: an assistant's reason, call and session,
    /// the proposal being applied, or the app's rule (plan 23 K).
    var cause = Cause()
    /// It repeats a task of the same name that failed — a failed change
    /// applied again read as the same delete twice (plan 21 N4).
    var isAgain = false
    /// Where it has got to — what separates a slow task from a stuck one.
    var stage = ""
    var progress = TaskProgress.running
    var message: String?
    let started: Date
    var finished: Date?
    /// How far it has got, when its owner counts: `done` of `total`, the
    /// total nil until known (plan 40).
    var done: Int?
    var total: Int?
    /// Its owner can pause it and resume it.
    var canPause = false
    /// It failed, and its owner can try it again (plan 44 E).
    var canRetry = false
    /// Who last paused or resumed it, why and when.
    var pause: PauseMark?

    var isFinished: Bool { progress != .running && progress != .paused }
    var isPaused: Bool { progress == .paused }
    var wentWrong: Bool { progress == .failed || progress == .cancelled }

    /// "120 of 288", or "120" while the total is not known; nil when it
    /// does not count.
    var countText: String? {
        guard let done else { return nil }
        return total.map { String(localized: "\(done) of \($0)") } ?? "\(done)"
    }
    /// How much of it is done, 0 to 1, when that is known.
    var fraction: Double? {
        guard let done, let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// How long it ran, or has been running.
    func elapsed(now: Date = Date()) -> TimeInterval {
        (finished ?? now).timeIntervalSince(started)
    }
}

/// A pause, or the resume after it: who, why and when (plan 40).
struct PauseMark: Equatable, Sendable {
    let by: Initiator
    let cause: Cause
    let at: Date
    /// False for a pause, true for the resume after it.
    let resumed: Bool
}
