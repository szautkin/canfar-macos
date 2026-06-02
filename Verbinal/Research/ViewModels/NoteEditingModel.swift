// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Editing state for a single observation's note, backed by ``ObservationNoteStore``.
///
/// Extracted from `ObservationNotesView` so the load/flush *keying* is unit-testable
/// and, crucially, correct under SwiftUI view reuse.
///
/// ## The bug this fixes
/// `ObservationNotesView` is shown in the Research detail pane without a per-observation
/// `.id()`, so when the selection changes SwiftUI *reuses the same view instance* and
/// swaps `publisherID` in place. The previous design committed pending edits inside
/// `load()` using `self.publisherID` — which had already become the *new* observation's
/// id — writing the previous note's text onto the newly-selected observation. Repeated
/// navigation propagated one note across many observations ("same notes for every item").
///
/// This model fixes it by remembering the id the in-memory fields actually belong to
/// (``loadedID``) and always committing under *that* key. Switching observations flushes
/// the outgoing edits under the outgoing id, then loads the incoming note.
@MainActor
@Observable
final class NoteEditingModel {
    private let store: ObservationNoteStore

    /// The publisherID the current `text`/`rating`/`tags` belong to. `nil` until the
    /// first `load`. All commits key off this — never an externally-supplied id that
    /// may already point at a different observation.
    private(set) var loadedID: String?

    var text: String = ""
    var rating: Int = 0
    var tagsInput: String = ""
    private(set) var modifiedAt: Date?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(store: ObservationNoteStore) {
        self.store = store
    }

    var parsedTags: [String] {
        tagsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rating == 0 && parsedTags.isEmpty
    }

    /// Load the note for `publisherID`. First flushes any pending edits under the
    /// *previously* loaded id (so edits never leak onto a different observation),
    /// then replaces the in-memory fields with the requested note.
    func load(publisherID: String) {
        saveTask?.cancel()
        if let loadedID, loadedID != publisherID {
            commit(for: loadedID)
        }
        let existing = store.note(for: publisherID)
        text = existing?.text ?? ""
        rating = existing?.rating ?? 0
        tagsInput = existing?.tags.joined(separator: ", ") ?? ""
        modifiedAt = existing?.modifiedAt
        loadedID = publisherID
    }

    /// Debounced autosave (500ms) for the currently-loaded note. No-op before the
    /// first `load` so an initial field assignment can't write a blank note.
    func scheduleSave() {
        guard loadedID != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Commit pending edits immediately under the currently-loaded id. Safe to call
    /// from `.onDisappear` / on teardown.
    func flush() {
        saveTask?.cancel()
        if let loadedID {
            commit(for: loadedID)
        }
    }

    /// Clear the currently-loaded note (deletes it from the store).
    func clear() {
        saveTask?.cancel()
        text = ""
        rating = 0
        tagsInput = ""
        if let loadedID {
            store.remove(publisherID: loadedID)
        }
        modifiedAt = nil
    }

    private func commit(for id: String) {
        let existing = store.note(for: id)
        let note = ObservationNote(
            publisherID: id,
            text: text,
            rating: rating,
            tags: parsedTags,
            createdAt: existing?.createdAt ?? Date(),
            modifiedAt: Date()
        )
        store.save(note)
        // Only reflect the saved timestamp back into the UI when we just committed
        // the note the fields still represent (not an outgoing flush during a switch).
        if id == loadedID {
            modifiedAt = store.note(for: id)?.modifiedAt
        }
    }
}
