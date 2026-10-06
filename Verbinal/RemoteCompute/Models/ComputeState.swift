// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Where remote compute stands, as the Remote Compute screen and
/// `get_compute_state` say it. The raw values are the wire names.
enum ComputeState: String, Codable, Sendable {
    /// No compute image in Settings ▸ AI Compute: nothing can run.
    case notSetUp
    /// Set up, with no compute session on the platform.
    case stopped
    /// Asked for and not running yet — a contributed session takes a minute or two.
    case starting
    /// Asked for, and the platform cannot start it — its image cannot be
    /// pulled: it never will, until it is stopped and the image put right.
    case notReady
    case running
    /// Being torn down.
    case stopping
    /// The platform says it failed; it keeps its name until it is deleted.
    case failed

    /// The state for a compute session's platform status; nil or a finished
    /// session means none. A live session is what it is whether or not an
    /// image is set here — one left from another install still holds the
    /// person's cores, and must be seen to be stopped.
    init(configured: Bool, sessionStatus: String?) {
        let none: ComputeState = configured ? .stopped : .notSetUp
        switch sessionStatus?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "pending": self = .starting
        case "running": self = .running
        case "terminating": self = .stopping
        case "failed", "error": self = .failed
        default: self = none
        }
    }

    /// Start when there is no session to reuse — a failed one is replaced —
    /// and an image is set: choosing it is the person's consent.
    func canStart(configured: Bool) -> Bool {
        configured && (self == .stopped || self == .failed)
    }

    /// Stop whenever a session exists and is not already going, set up or
    /// not: a session nobody can stop is the thing to avoid.
    var canStop: Bool { self == .starting || self == .running || self == .failed || self == .notReady }

    /// Code can be sent whenever compute is set up; a stopped session is
    /// started for it. Not to one that cannot start.
    func canRun(configured: Bool) -> Bool {
        configured && self != .notSetUp && self != .stopping && self != .notReady
    }

    /// Why a starting session cannot start, from its platform events; nil
    /// while nothing says it cannot. A session whose image CANFAR cannot
    /// pull sat "starting" for good (handout 31).
    static func notReadyReason(events: String, image: String) -> String? {
        let pullFailures = ["ErrImagePull", "ImagePullBackOff", "InvalidImageName"]
        guard pullFailures.contains(where: events.contains) else { return nil }
        return String(localized: "CANFAR cannot pull the compute image \(image): check it in Settings ▸ AI Compute, and that its registry lets CANFAR pull it. The session will not start; stop it.")
    }

    /// How long a session has been up, from the platform's start time; nil
    /// when it does not parse or lies in the future — a clock that disagrees
    /// says nothing rather than a negative uptime.
    static func uptime(startedAt: String?, now: Date = Date()) -> TimeInterval? {
        guard let started = startedAt.flatMap(SharedFormatters.isoDate) else { return nil }
        let up = now.timeIntervalSince(started)
        return up < 0 ? nil : up
    }
}

/// Where remote compute stands: its state, its session if there is one,
/// and what it launches. Set up and running are separate facts.
struct ComputeSnapshot: Sendable {
    let state: ComputeState
    let session: Session?
    let configuration: RemoteComputeService.Configuration
    /// Why it is not ready, when it is not.
    var problem: String? = nil
}
