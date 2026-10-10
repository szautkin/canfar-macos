// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a Research record is found by.
protocol ResearchFilterable {
    var publisherID: String { get }
    var targetName: String { get }
    var collection: String { get }
    var instrument: String { get }
    var observationID: String { get }
}

extension DownloadedObservation: ResearchFilterable {}

/// Which Research records some words find — one rule for the screen's
/// filter and `list_downloaded_observations` (plan 36 2.10): the words in
/// the target, collection, instrument or observation id, or in what the
/// person wrote about the record, its note's text or tags.
struct ResearchFilter {
    /// Lowercased and trimmed; empty finds every record.
    let words: String
    /// The records whose note's text or tags hold the words: the note index's answer.
    let noteMatches: Set<String>

    init(_ text: String, noteMatches: Set<String>) {
        words = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.noteMatches = noteMatches
    }

    /// With the note index's answer for `text`.
    @MainActor
    init(_ text: String, notes: ObservationNoteStore) {
        self.init(text, noteMatches: Set(notes.searchPublisherIDs(matching: text)))
    }

    func keeps(_ record: some ResearchFilterable) -> Bool {
        guard !words.isEmpty else { return true }
        return [record.targetName, record.collection, record.instrument, record.observationID]
            .contains { $0.lowercased().contains(words) }
            || noteMatches.contains(record.publisherID)
    }
}
