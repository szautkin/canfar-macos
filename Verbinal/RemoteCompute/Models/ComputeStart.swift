// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What starting the compute session did: launched one at the size asked,
/// or kept the one already running — at its own size, which a running
/// session keeps. `start_compute` said "4 cores / 8 GB" while it kept a
/// 1-core session (plan 19 S3, QA N18).
enum ComputeStart: Equatable, Sendable {
    case launched(cores: Int, ram: Int)
    /// The running session's own cores and memory, as the platform reports
    /// them, and how it differs from what was asked.
    case reused(cores: String, memory: String, drift: ComputeDrift?)

    var reusedExisting: Bool {
        if case .reused = self { return true }
        return false
    }

    /// One sentence for a person or an agent.
    var sentence: String {
        let name = RunCodeContract.sessionName
        switch self {
        case .launched(let cores, let ram):
            return "Launched the \(name) session with \(cores) cores and \(ram) GB. Run code on it with run_code."
        case .reused(let cores, let memory, let drift):
            let size = [ComputeDrift.cores(cores).map { "\(ComputeDrift.number($0)) \($0 == 1 ? "core" : "cores")" },
                        ComputeDrift.gigabytes(memory).map { "\(ComputeDrift.number($0)) GB" }]
                .compactMap { $0 }.joined(separator: " and ")
            let has = size.isEmpty ? "" : ", which has \(size)"
            let differs = drift.map { " \($0.sentence) To change it: stop_compute, then start_compute." } ?? ""
            return "Kept the \(name) session already running\(has).\(differs)"
        }
    }
}
