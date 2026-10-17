// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import VerbinalKit

/// One Research record, as kept in VOSpace (plan 34 V):
/// `.verbinal/research/<key>.json`. The observation's details and the
/// person's note — not its files, nor anything of this Mac (paths,
/// bookmarks). `removedAt` marks a record the person removed, so other
/// devices remove it too; a missing item means nothing.
struct ResearchItem: SyncItem {
    static let format = 1

    struct Details: Codable, Equatable, Sendable {
        var publisherID: String
        var collection: String
        var observationID: String
        var targetName: String
        var instrument: String
        var filter: String
        var ra: String
        var dec: String
        var startDate: String
        var calLevel: String
        var thumbnailURL: String?
        var previewURL: String?
        var cutout: CutoutSpec?
    }

    struct Note: Codable, Equatable, Sendable {
        var text: String
        var rating: Int
        var tags: [String]
    }

    var format: Int = 1
    /// The record's identity across devices: its publisher ID, and which
    /// cutout of it.
    var recordKey: String
    /// When it last changed, wherever.
    var changedAt: Date
    var removedAt: Date?
    var details: Details
    var note: Note?
    /// The item as it was read from storage, whole: the fields this build
    /// does not know — a later build's — go back with it (plan 36 1.8).
    var stored: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case format, recordKey, changedAt, removedAt, details, note
    }

    var key: String { recordKey }
}

/// Research as the person's work in VOSpace (plan 34 V, 36 3.1).
extension ResearchModel {
    func syncCollection() -> WorkCollection {
        let store = observationStore, notes = noteStore
        return WorkCollection(
            kind: CollectionKind(id: "research", defaultFolder: ".verbinal/research",
                                 collection: ResearchSyncAdapter(store: store, notes: notes)),
            watch: {
                _ = store.observations
                _ = notes.notes
            })
    }
}

/// Research on this Mac, for the storage sync (plan 34 V): its records and
/// notes as items, and items from another device kept as records. Research
/// knows nothing of the sync.
@MainActor
final class ResearchSyncAdapter: SyncCollection {
    private let store: ObservationStore
    private let notes: ObservationNoteStore

    init(store: ObservationStore, notes: ObservationNoteStore) {
        self.store = store
        self.notes = notes
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

    func remove(key: String) async {
        guard let record = store.observations.first(where: { $0.recordKey == key }) else { return }
        // Who removed it, and why, as the sync says — another device's
        // removal, or the choice on a conflict (plan 45) — and its files stay.
        var cause = Cause.current
        cause.why = [cause.why ?? "removed from Research", "its files stay on this Mac"].joined(separator: "; ")
        Cause.$current.withValue(cause) {
            store.remove(record)
        }
    }

    nonisolated func title(of item: ResearchItem) -> String {
        let what = [item.details.targetName, item.details.observationID].filter { !$0.isEmpty }.joined(separator: ", ")
        return "the Research record \(what)"
    }
}
