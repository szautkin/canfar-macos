// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - View

/// Astronomer's notebook for a single observation: quality rating, tags, and free-form notes.
/// Auto-saves on edit with a 500ms debounce. Clearing all fields deletes the note.
///
/// All editing state and the load/save *keying* live in ``NoteEditingModel`` so that
/// committing always targets the note the in-memory fields actually belong to — even when
/// SwiftUI reuses this view in place across observation selections (see NoteEditingModel
/// for the cross-contamination bug this prevents).
struct ObservationNotesView: View {
    let publisherID: String
    @State private var editor: NoteEditingModel

    init(publisherID: String, store: ObservationNoteStore) {
        self.publisherID = publisherID
        _editor = State(initialValue: NoteEditingModel(store: store))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        @Bindable var editor = editor
        return VStack(alignment: .leading, spacing: 10) {
            header
            ratingRow

            // Tags
            HStack(spacing: 4) {
                Text("Tags")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                TextField("e.g. usable, calibration, reprocess", text: $editor.tagsInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: editor.tagsInput) { _, _ in editor.scheduleSave() }
            }

            // Notes editor
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, lineWidth: 1)

                TextEditor(text: $editor.text)
                    .font(.system(.caption, design: .default))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 120)
                    .onChange(of: editor.text) { _, _ in editor.scheduleSave() }

                if editor.text.isEmpty {
                    Text("Observing conditions, calibration notes, reduction steps, reminders…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 13)
                        .allowsHitTesting(false)
                }
            }

            footerRow
        }
        .task(id: publisherID) {
            editor.load(publisherID: publisherID)
        }
        .onDisappear {
            // Flush any pending save when the view is torn down (selection change, tab switch).
            // Commits under the loaded id, never a stale one.
            editor.flush()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Notes")
                .font(.subheadline.bold())
            Spacer()
            if let modifiedAt = editor.modifiedAt {
                Text("Edited \(Self.relativeFormatter.localizedString(for: modifiedAt, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            #if os(macOS)
            Button {
                copyToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(editor.text.isEmpty)
            .help("Copy notes to clipboard")
            #endif
        }
    }

    private var ratingRow: some View {
        HStack(spacing: 4) {
            Text("Quality")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            ForEach(1...5, id: \.self) { star in
                Button {
                    // Tap same star again to clear, otherwise set to that star.
                    editor.rating = (editor.rating == star) ? 0 : star
                    editor.scheduleSave()
                } label: {
                    Image(systemName: star <= editor.rating ? "star.fill" : "star")
                        .foregroundStyle(star <= editor.rating ? Color.yellow : Color.secondary)
                        .font(.callout)
                }
                .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
                .help("Set rating to \(star)")
                .buttonStyle(.plain)
                .help("Rate \(star) star\(star == 1 ? "" : "s")")
            }

            if editor.rating > 0 {
                // qualityLabel returns a LocalizedStringKey so Text routes
                // through the String Catalog (each star tier has a FR value).
                Text(qualityLabel(editor.rating))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quality rating \(editor.rating) of 5")
    }

    private var footerRow: some View {
        HStack {
            if !editor.text.isEmpty {
                // Coerce to String so the interpolation key is `%@ words`
                // (what Xcode extracts for object interpolations).
                // `\(wordCount)` as a raw Int would auto-generate `%lld words`,
                // which wouldn't match the object-typed catalog entry.
                Text("\(String(wordCount)) words")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
            if !editor.isEmpty {
                Button(role: .destructive) {
                    editor.clear()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .font(.caption2)
            }
        }
    }

    // MARK: - Helpers

    private var wordCount: Int {
        editor.text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func qualityLabel(_ stars: Int) -> LocalizedStringKey {
        switch stars {
        case 1: return "Unusable"
        case 2: return "Poor"
        case 3: return "Fair"
        case 4: return "Good"
        case 5: return "Excellent"
        default: return ""
        }
    }

    #if os(macOS)
    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(editor.text, forType: .string)
    }
    #endif
}
