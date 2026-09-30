// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// Brings Research's records up to the archive, after each sign-in.
///
/// Records kept before their details came from the archive said what they
/// were given (plan 17 G3). The first check asked `caom2ops/meta` for every
/// record, one at a time — 30–50 s each under load, 35 records in about
/// 20 minutes (QA N15) — and was done once, whether the archive answered or
/// not. Now what the archive once answered is kept on this Mac
/// (`ArchiveObservations`): a record it answered for is completed from that,
/// at once; only the others are asked, two at a time, with the progress on
/// the activity bar and in Research; one the archive does not answer is
/// asked again at the next sign-in (plan 19 R1).
@Observable
@MainActor
final class ResearchRecordRepair {
    /// How far the check has got; nil when none is running.
    struct Progress: Equatable {
        var done: Int
        let total: Int
    }

    private(set) var progress: Progress?
    /// Archive requests at once — CADC serves everyone else too.
    static let concurrentRequests = 2
    /// How long one record waits for the archive.
    static let requestSeconds = RequestTimeout.standard
    /// No answer to this many requests, and none before: the archive is
    /// down. With it down, 36 records waited out 18 minutes and the check
    /// said it had succeeded (plan 21 D3).
    static let givesUpAfter = 4
    /// Why the app runs the check at all: its rule, for the session log
    /// (plan 23 K).
    static let rule = "at sign-in, Research records that lack their archive details are asked for them"
    /// Why a check ended without the archive's answers.
    static let notAnswering = String(localized: "The archive is not answering — Research records are asked again at the next sign-in")

    private let store: ObservationStore
    /// A corrected record's note goes with it.
    private let notes: ObservationNoteStore?
    private let tasks: TaskRegistry
    private let archive: any ArchiveObservations
    /// One check at a time, however many sign-ins ask for one.
    @ObservationIgnored private var running = false

    init(store: ObservationStore, notes: ObservationNoteStore? = nil, tasks: TaskRegistry = .shared,
         archive: any ArchiveObservations) {
        self.store = store
        self.notes = notes
        self.tasks = tasks
        self.archive = archive
    }

    /// Checks every record; returns how many it changed.
    @discardableResult
    func run() async -> Int {
        guard !running, !store.observations.isEmpty else { return 0 }
        running = true
        defer { running = false; progress = nil }

        var changed = correctSlashFormIDs()
        var toAsk: [DownloadedObservation] = []
        for record in store.observations {
            if let kept = await archive.kept(publisherID: record.publisherID) {
                if store.complete(recordID: record.id, from: kept) { changed += 1 }
            } else {
                toAsk.append(record)
            }
        }
        guard !toAsk.isEmpty else { return changed }

        let task = tasks.begin(.research, String(localized: "Get archive details for Research records"), by: .app,
                               why: Self.rule)
        progress = Progress(done: 0, total: toAsk.count)
        task.stage(String(localized: "\(0) of \(toAsk.count)"))
        var answered = 0, asked = 0
        let archive = archive, seconds = Self.requestSeconds
        await withTaskGroup(of: (UUID, CAOM2Observation?).self) { group in
            var next = 0
            func ask() {
                let id = toAsk[next].id, publisherID = toAsk[next].publisherID
                next += 1
                group.addTask { (id, await archive.observation(publisherID: publisherID, within: seconds)) }
            }
            while next < min(Self.concurrentRequests, toAsk.count) { ask() }
            for await (id, observation) in group {
                asked += 1
                if observation != nil { answered += 1 }
                if store.complete(recordID: id, from: observation) { changed += 1 }
                progress?.done += 1
                task.stage(String(localized: "\(progress?.done ?? 0) of \(toAsk.count)"))
                let archiveDown = answered == 0 && asked >= Self.givesUpAfter
                if next < toAsk.count, !archiveDown { ask() }
            }
        }
        // An archive that answered for none has not been checked against.
        if answered == 0 {
            task.fail(Self.notAnswering)
        } else {
            task.succeed(String(localized: "The archive answered for \(answered) of \(toAsk.count)"))
        }
        return changed
    }

    /// Records saved under the slash form, `ivo://cadc.nrc.ca/CFHT/1525350`,
    /// were never looked up — the person's blank `1525350` (plan 19 R3).
    /// Each gets the ID it means, with its note.
    private func correctSlashFormIDs() -> Int {
        var corrected = 0
        for record in store.observations where PublisherID(record.publisherID) == nil {
            guard let likely = PublisherID.likely(record.publisherID),
                  store.correctPublisherID(of: record.id, to: likely) != nil else { continue }
            notes?.move(from: record.publisherID, to: likely)
            corrected += 1
        }
        return corrected
    }
}
