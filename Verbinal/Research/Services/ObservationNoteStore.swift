// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

/// Persists per-observation notes in Application Support, keyed by publisherID.
/// Survives file deletion — notes are about the observation, not the local file copy.
@Observable
final class ObservationNoteStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ObservationNoteStore")
    private let persistence: DiskPersistence<[String: ObservationNote]>
    private(set) var notes: [String: ObservationNote] = [:]

    init(fileName: String = "observation_notes.json") {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger
        )
        self.notes = persistence.read() ?? [:]
    }

    func note(for publisherID: String) -> ObservationNote? {
        notes[publisherID]
    }

    /// Save a note. If the note is empty, it is removed entirely to avoid accumulating blank entries.
    func save(_ note: ObservationNote) {
        if note.isEmpty {
            remove(publisherID: note.publisherID)
            return
        }
        var updated = note
        updated.modifiedAt = Date()
        notes[note.publisherID] = updated
        persistence.write(notes)
    }

    func remove(publisherID: String) {
        guard notes[publisherID] != nil else { return }
        notes.removeValue(forKey: publisherID)
        persistence.write(notes)
    }
}
