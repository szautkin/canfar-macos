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
    /// v2: records kept under a slash-form publisher ID are corrected too
    /// (plan 19 R3), so a Mac that ran the first check runs this one.
    static let doneKey = "research.recordsCheckedAgainstArchive.v2"
    /// One check at a time, however many sign-ins ask for one.
    private var running = false

    private let store: ObservationStore
    /// A corrected record's note goes with it.
    private let notes: ObservationNoteStore?
    private let tasks: TaskRegistry
    private let defaults: UserDefaults
    /// The archive's record of an observation; nil when it does not answer.
    private let fetch: @Sendable (_ publisherID: String) async -> CAOM2Observation?

    init(store: ObservationStore, notes: ObservationNoteStore? = nil, tasks: TaskRegistry = .shared,
         defaults: UserDefaults = .standard, fetch: @escaping @Sendable (String) async -> CAOM2Observation?) {
        self.store = store
        self.notes = notes
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
        let task = tasks.begin(.research, String(localized: "Check Research records against the archive"), by: .app)
        var corrected = 0, answered = 0
        for (index, kept) in records.enumerated() {
            task.stage(String(localized: "\(index + 1) of \(records.count)"))
            var record = kept
            // Saved under the slash form, it was never looked up: `1525350`,
            // blank in the person's Research (plan 19 R3).
            if PublisherID(record.publisherID) == nil, let likely = PublisherID.likely(record.publisherID),
               let corrected = store.correctPublisherID(of: record.id, to: likely) {
                notes?.move(from: record.publisherID, to: likely)
                record = corrected
            }
            let archive = await fetch(record.publisherID)
            if archive != nil { answered += 1 }
            let completed = ResearchRecordDetails.completing(record, from: archive)
            guard completed != kept else { continue }
            store.save(completed)
            corrected += 1
        }
        if answered > 0 { defaults.set(true, forKey: Self.doneKey) }
        task.succeed(String(localized: "Corrected \(corrected) of \(records.count)"))
        return corrected
    }
}
