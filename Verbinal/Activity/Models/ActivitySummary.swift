// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// The tasks as words on the activity bar — the part worth being sure of:
/// "Idle" while something runs, or a permanent "0 failed", is how a status
/// bar becomes furniture.
enum ActivitySummary {
    /// One task in the expanded list: what it is, and where it got to.
    struct Line: Equatable {
        let title: String
        let detail: String
        let progress: TaskProgress
        /// Who started it, in words.
        var startedBy = ""
        /// The task, for its Pause and Resume.
        var id = 0
        var canPause = false
        /// How much is done, 0 to 1, when it counts.
        var fraction: Double?
    }

    /// Who paused a task, as the bar says it.
    static func pausedBy(_ initiator: Initiator) -> String {
        switch initiator {
        case .person: return String(localized: "Paused by you")
        case .assistant: return String(localized: "Paused by your assistant")
        case .app: return String(localized: "Paused by Verbinal")
        }
    }

    /// Where a running task has got to: its stage and its count, "Image
    /// package lists, 120 of 288"; nil when it says neither.
    static func whereItIs(_ task: TrackedTask) -> String? {
        switch (task.stage.isEmpty ? nil : task.stage, task.countText) {
        case (let stage?, let count?): return "\(stage), \(count)"
        case (let stage?, nil): return stage
        case (nil, let count?): return count
        case (nil, nil): return nil
        }
    }

    /// Who started a task, as the bar says it.
    static func who(_ initiator: Initiator) -> String {
        switch initiator {
        case .person: return String(localized: "You")
        case .assistant: return String(localized: "Your assistant")
        case .app: return String(localized: "Verbinal")
        }
    }

    /// The one line the bar costs. A single running task names itself, with
    /// its stage; several become a count — five labels on one line is not a
    /// line anybody reads.
    /// What is paused is said too: the bar is never "Idle" while something
    /// waits for someone to resume it (plan 40).
    static func line(_ tasks: [TrackedTask]) -> String {
        let running = tasks.filter { $0.progress == .running }
        let paused = tasks.filter(\.isPaused)
        let doing: String? = switch running.count {
        case 0: nil
        case 1: whereItIs(running[0]).map { "\(running[0].label) — \($0)" } ?? running[0].label
        default: String(localized: "\(running.count) tasks running")
        }
        let held: String? = switch paused.count {
        case 0: nil
        case 1 where doing == nil: String(localized: "\(paused[0].label) — paused")
        default: String(localized: "\(paused.count) paused")
        }
        let line = [doing, held].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? String(localized: "Idle") : line
    }

    /// How many went wrong, or nil when none did: a permanent zero is noise.
    static func failures(_ tasks: [TrackedTask]) -> String? {
        let failed = tasks.filter(\.wentWrong).count
        return failed == 0 ? nil : String(localized: "\(failed) failed")
    }

    /// Newest first — a list opened to find out what just happened starts with it.
    static func lines(_ tasks: [TrackedTask], now: Date = Date()) -> [Line] {
        tasks.reversed().map { describe($0, now: now) }
    }

    /// A failure shows its reason; anything else how long it took, or has
    /// been going.
    static func describe(_ task: TrackedTask, now: Date = Date()) -> Line {
        let took = duration(task.elapsed(now: now))
        let detail: String
        switch task.progress {
        case .failed:
            detail = task.message.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "failed, no reason given")
        case .cancelled:
            // Not "cancelled": nobody chose this — a path returned early or a window closed.
            detail = String(localized: "abandoned before it finished")
        case .succeeded:
            detail = task.message.flatMap { $0.isEmpty ? nil : "\($0) · \(took)" } ?? took
        case .running:
            detail = whereItIs(task).map { "\($0) · \(took)" } ?? took
        case .paused:
            detail = [task.pause.map { pausedBy($0.by) } ?? String(localized: "Paused"), whereItIs(task)]
                .compactMap { $0 }.joined(separator: " · ")
        }
        let title = task.isAgain ? String(localized: "\(task.label), again") : task.label
        return Line(title: title, detail: detail, progress: task.progress, startedBy: who(task.startedBy),
                    id: task.id, canPause: task.canPause && !task.isFinished, fraction: task.fraction)
    }

    /// At the precision a person reads: under a second is "just now".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        switch seconds {
        case ..<1: return String(localized: "just now")
        case ..<60: return "\(whole)s"
        case ..<3600: return "\(whole / 60)m \(whole % 60)s"
        default: return "\(whole / 3600)h \(whole % 3600 / 60)m"
        }
    }
}
