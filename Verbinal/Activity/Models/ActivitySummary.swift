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
    static func line(_ tasks: [TrackedTask]) -> String {
        let running = tasks.filter { !$0.isFinished }
        switch running.count {
        case 0: return String(localized: "Idle")
        case 1: return running[0].stage.isEmpty ? running[0].label : "\(running[0].label) — \(running[0].stage)"
        default: return String(localized: "\(running.count) tasks running")
        }
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
            detail = task.stage.isEmpty ? took : "\(task.stage) · \(took)"
        }
        return Line(title: task.label, detail: detail, progress: task.progress, startedBy: who(task.startedBy))
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
