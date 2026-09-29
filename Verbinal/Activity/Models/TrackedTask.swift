// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

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
}

/// Where a task got to.
enum TaskProgress: String, Codable, Sendable {
    case running
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
    /// Where it has got to — what separates a slow task from a stuck one.
    var stage = ""
    var progress = TaskProgress.running
    var message: String?
    let started: Date
    var finished: Date?

    var isFinished: Bool { progress != .running }
    var wentWrong: Bool { progress == .failed || progress == .cancelled }

    /// How long it ran, or has been running.
    func elapsed(now: Date = Date()) -> TimeInterval {
        (finished ?? now).timeIntervalSince(started)
    }
}
