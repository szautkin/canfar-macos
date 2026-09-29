// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Brings the Research records kept before a record's details came from
/// the archive (plan 15 F6) up to it, once: each is completed as a new one
/// is (``ResearchRecordDetails``) and saved when that changes it.
///
/// The regression run still found the M31 MegaPipe record saying g band
/// for its u-band file, and records with no observation id (QA H5, M2).
@MainActor
final class ResearchRecordRepair {
    static let doneKey = "research.recordsCheckedAgainstArchive"
    /// One check at a time, however many sign-ins ask for one.
    private var running = false

    private let store: ObservationStore
    private let tasks: TaskRegistry
    private let defaults: UserDefaults
    /// The archive's record of an observation; nil when it does not answer.
    private let fetch: @Sendable (_ publisherID: String) async -> CAOM2Observation?

    init(store: ObservationStore, tasks: TaskRegistry = .shared, defaults: UserDefaults = .standard,
         fetch: @escaping @Sendable (String) async -> CAOM2Observation?) {
        self.store = store
        self.tasks = tasks
        self.defaults = defaults
        self.fetch = fetch
    }

    /// Checks every record, unless that has been done; returns how many it
    /// corrected. Done once the archive has answered at least once — a
    /// check made offline is made again.
    @discardableResult
    func runOnce() async -> Int {
        let records = store.observations
        guard !running, !defaults.bool(forKey: Self.doneKey), !records.isEmpty else { return 0 }
        running = true
        defer { running = false }
        let task = tasks.begin(.research, String(localized: "Check Research records against the archive"))
        var corrected = 0, answered = 0
        for (index, record) in records.enumerated() {
            task.stage(String(localized: "\(index + 1) of \(records.count)"))
            let archive = await fetch(record.publisherID)
            if archive != nil { answered += 1 }
            let completed = ResearchRecordDetails.completing(record, from: archive)
            guard completed != record else { continue }
            store.save(completed)
            corrected += 1
        }
        if answered > 0 { defaults.set(true, forKey: Self.doneKey) }
        task.succeed(String(localized: "Corrected \(corrected) of \(records.count)"))
        return corrected
    }
}
