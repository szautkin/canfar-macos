// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Research on this Mac, for the storage sync (plan 34 V): its records and
/// notes as items, and items from another device kept as records. Research
/// knows nothing of the sync.
@MainActor
final class ResearchSyncAdapter: ResearchSyncSource {
    private let store: ObservationStore
    private let notes: ObservationNoteStore
    private let replacedFolder: URL
    private let changes: ChangeLog

    init(store: ObservationStore, notes: ObservationNoteStore,
         replacedFolder: URL = StorageSyncState.productionDirectory.appendingPathComponent("replaced", isDirectory: true),
         changes: ChangeLog = .shared) {
        self.store = store
        self.notes = notes
        self.replacedFolder = replacedFolder
        self.changes = changes
    }

    func items() async -> [ResearchItem] {
        store.observations.map { record in
            let note = notes.note(for: record.publisherID)
            return ResearchItem(
                recordKey: record.recordKey,
                changedAt: max(record.downloadedAt, note?.modifiedAt ?? .distantPast),
                details: .init(publisherID: record.publisherID, collection: record.collection,
                               observationID: record.observationID, targetName: record.targetName,
                               instrument: record.instrument, filter: record.filter, ra: record.ra, dec: record.dec,
                               startDate: record.startDate, calLevel: record.calLevel,
                               thumbnailURL: record.thumbnailURL, previewURL: record.previewURL, cutout: record.cutout),
                note: note.map { .init(text: $0.text, rating: $0.rating, tags: $0.tags) })
        }
    }

    func apply(_ item: ResearchItem) async {
        Initiator.$current.withValue(.app) {
            Cause.$current.withValue(Cause(why: "a change to Research from another device")) {
                let details = item.details
                var record = store.observations.first { $0.recordKey == item.recordKey }
                    ?? DownloadedObservation(publisherID: details.publisherID, collection: details.collection,
                                             observationID: details.observationID, targetName: details.targetName,
                                             instrument: details.instrument, filter: details.filter, ra: details.ra,
                                             dec: details.dec, startDate: details.startDate, calLevel: details.calLevel,
                                             localPath: "", downloadedAt: item.changedAt)
                record.collection = details.collection
                record.observationID = details.observationID
                record.targetName = details.targetName
                record.instrument = details.instrument
                record.filter = details.filter
                record.ra = details.ra
                record.dec = details.dec
                record.startDate = details.startDate
                record.calLevel = details.calLevel
                record.thumbnailURL = details.thumbnailURL
                record.previewURL = details.previewURL
                record.cutout = details.cutout
                store.save(record)

                let current = notes.note(for: details.publisherID)
                if let note = item.note {
                    if current?.text != note.text || current?.rating != note.rating || current?.tags != note.tags {
                        notes.save(ObservationNote(publisherID: details.publisherID, text: note.text, rating: note.rating,
                                                   tags: note.tags, createdAt: current?.createdAt ?? item.changedAt))
                    }
                } else if current != nil, item.details.cutout == nil {
                    notes.remove(publisherID: details.publisherID)
                }
            }
        }
    }

    func remove(recordKey: String) async {
        guard let record = store.observations.first(where: { $0.recordKey == recordKey }) else { return }
        Initiator.$current.withValue(.app) {
            Cause.$current.withValue(Cause(why: "removed from Research on another device; its files stay on this Mac")) {
                store.remove(record)
            }
        }
    }

    /// Kept on this Mac, never in a log: notes are the person's words.
    func replaced(_ item: ResearchItem, by newer: ResearchItem) async {
        try? FileManager.default.createDirectory(at: replacedFolder, withIntermediateDirectories: true)
        let name = "\(item.fileName.dropLast(5))-\(Int(Date().timeIntervalSince1970)).json"
        try? item.encoded().write(to: replacedFolder.appendingPathComponent(name), options: .atomic)
        let what = [item.details.targetName, item.details.observationID].filter { !$0.isEmpty }.joined(separator: ", ")
        Initiator.$current.withValue(.app) {
            Cause.$current.withValue(Cause(why: "the newer change wins; the one it replaced is kept in Verbinal's folder, StorageSync/replaced")) {
                changes.done("sync_research", "Research record \(what): kept the newer of two changes")
            }
        }
    }
}
