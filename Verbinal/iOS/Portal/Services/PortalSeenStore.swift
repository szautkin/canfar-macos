// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// The failed batch jobs the person has looked at on this device: news once,
/// then no longer under Needs attention (plan 47 1.3). Kept on the device only.
@Observable
@MainActor
final class PortalSeenStore {
    static let key = "ios.portal.seenFailedJobs"

    private let defaults: UserDefaults
    private(set) var seenFailedJobs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.seenFailedJobs = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// These failed jobs are seen. Only jobs still failed are kept, so the
    /// list never outgrows what the platform still lists.
    func markSeen(_ jobIDs: some Sequence<String>, stillFailed: Set<String>) {
        seenFailedJobs = seenFailedJobs.union(jobIDs).intersection(stillFailed)
        defaults.set(Array(seenFailedJobs).sorted(), forKey: Self.key)
    }
}
