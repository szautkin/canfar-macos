// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// How the live compute session differs from what Settings would launch now.
///
/// A session keeps the image and size it started with; Settings changed
/// since do not reach it until it is stopped and started again. `run_code`
/// reused an older session silently — Settings said
/// `verbinal-execution:0.0.1`, 4 cores, 8 GB; the session ran 0.0.2 with 1
/// core and 1.07 GB (QA M7). The platform can also grant less than asked,
/// so a smaller session is said to be smaller, not why.
struct ComputeDrift: Equatable, Sendable {
    /// Each way it differs, as a phrase: "runs …:0.0.2, not …:0.0.1".
    let differences: [String]

    /// Nil when the session is not live or matches.
    init?(session: Session, configuration: RemoteComputeService.Configuration) {
        guard RunCodeContract.isLive(session.status), configuration.isConfigured else { return nil }
        var differences: [String] = []
        let image = session.containerImage.trimmingCharacters(in: .whitespaces)
        if !image.isEmpty, image != configuration.image {
            differences.append("runs \(image), not \(configuration.image)")
        }
        let cores = RunCodeContract.clampCores(configuration.cores)
        if let has = Self.cores(session.cpuAllocated), has < Double(cores) {
            differences.append("has \(Self.number(has)) of the \(cores) cores Settings ask")
        }
        let ram = RunCodeContract.clampRam(configuration.ram)
        if let has = PlatformMemory.gigabytes(session.memoryAllocated), has < Double(ram) - 0.05 {
            differences.append("has \(Self.number(has)) of the \(ram) GB Settings ask")
        }
        guard !differences.isEmpty else { return nil }
        self.differences = differences
    }

    /// One sentence for a person or an agent.
    var sentence: String {
        "The compute session " + differences.joined(separator: ", and ")
            + " — it keeps what it started with until it is stopped and started again."
    }

    /// Cores as the platform reports them ("4", "1.0"); nil when unreadable.
    static func cores(_ allocated: String) -> Double? {
        Double(allocated.trimmingCharacters(in: .whitespaces))
    }

    /// 1, 1.5, 1.07 — as few decimals as the value needs.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}

extension ComputeSnapshot {
    /// How its live session differs from Settings; nil when it does not.
    var drift: ComputeDrift? { session.flatMap { ComputeDrift(session: $0, configuration: configuration) } }
}
