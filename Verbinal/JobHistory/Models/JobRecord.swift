// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One finished batch job, kept after CANFAR has forgotten it.
///
/// The platform reaps batch jobs, and image discovery deletes its probe
/// jobs the moment they end, so a job could fail and, a minute later, be
/// gone from the listing with its logs — the only trace a count that
/// ticked from Running to Failed. This keeps the outcome, when, and a
/// failure's reason, taken while the job still existed.
struct JobRecord: Codable, Equatable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
    }

    /// What launched it: the person, or image discovery on their behalf.
    enum Origin: String, Codable, Sendable {
        case user
        case imageProbe
    }

    /// The platform's job id — also what makes two records the same job.
    let id: String
    var name: String
    var image: String
    var origin: Origin
    var outcome: Outcome
    /// The status the platform last reported, verbatim — the evidence
    /// behind `outcome`.
    var status: String
    var startedAt: String
    var finishedAt: Date
    /// Why it failed, in as much detail as could be had — the point of it all.
    var failureReason: String?
    /// The image a probe was inspecting.
    var targetImage: String?

    /// What it was, for a row: a batch job, or the inspection of an image.
    var summary: String {
        guard origin == .imageProbe else { return String(localized: "Batch job") }
        return targetImage.map { String(localized: "Image inspection — \($0)") } ?? String(localized: "Image inspection")
    }

    /// This record, keeping what `earlier` knew that it does not: a probe
    /// stays a probe, and a reason once had is not lost to a later
    /// sighting of the same job that knows only its status.
    func keeping(_ earlier: JobRecord) -> JobRecord {
        var merged = self
        if earlier.origin == .imageProbe { merged.origin = .imageProbe }
        merged.targetImage = targetImage ?? earlier.targetImage
        if outcome == earlier.outcome, let reason = earlier.failureReason, (failureReason ?? "").count < reason.count {
            merged.failureReason = reason
        }
        if name.isEmpty { merged.name = earlier.name }
        if image.isEmpty { merged.image = earlier.image }
        if startedAt.isEmpty { merged.startedAt = earlier.startedAt }
        return merged
    }
}
