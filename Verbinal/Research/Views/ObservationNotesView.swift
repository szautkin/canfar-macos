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
struct ObservationNotesView: View {
    let publisherID: String
    var store: ObservationNoteStore

    @State private var text: String = ""
    @State private var rating: Int = 0
    @State private var tagsInput: String = ""
    @State private var modifiedAt: Date?
    @State private var saveTask: Task<Void, Never>?
    @State private var loaded = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ratingRow
            tagsRow
            notesEditor
            footerRow
        }
        .task(id: publisherID) {
            load()
        }
        .onDisappear {
            // Flush any pending save when the view is torn down (selection change, tab switch).
            saveTask?.cancel()
            commitSave()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Notes")
                .font(.subheadline.bold())
            Spacer()
            if let modifiedAt {
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
            .disabled(text.isEmpty)
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
                    rating = (rating == star) ? 0 : star
                    scheduleSave()
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                        .font(.callout)
                }
                .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
                .help("Set rating to \(star)")
                .buttonStyle(.plain)
                .help("Rate \(star) star\(star == 1 ? "" : "s")")
            }

            if rating > 0 {
                // qualityLabel returns a LocalizedStringKey so Text routes
                // through the String Catalog (each star tier has a FR value).
                Text(qualityLabel(rating))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quality rating \(rating) of 5")
    }

    private var tagsRow: some View {
        HStack(spacing: 4) {
            Text("Tags")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            TextField("e.g. usable, calibration, reprocess", text: $tagsInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: tagsInput) { _, _ in scheduleSave() }
        }
    }

    private var notesEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)

            TextEditor(text: $text)
                .font(.system(.caption, design: .default))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 120)
                .onChange(of: text) { _, _ in scheduleSave() }

            if text.isEmpty {
                Text("Observing conditions, calibration notes, reduction steps, reminders…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 13)
                    .allowsHitTesting(false)
            }
        }
    }

    private var footerRow: some View {
        HStack {
            if !text.isEmpty {
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
            if !isEmpty {
                Button(role: .destructive) {
                    clearAll()
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
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rating == 0 && parsedTags.isEmpty
    }

    private var parsedTags: [String] {
        tagsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    // MARK: - Load / Save

    private func load() {
        // Cancel any pending save from a previous observation before switching.
        saveTask?.cancel()
        if loaded { commitSave() }

        let existing = store.note(for: publisherID)
        text = existing?.text ?? ""
        rating = existing?.rating ?? 0
        tagsInput = existing?.tags.joined(separator: ", ") ?? ""
        modifiedAt = existing?.modifiedAt
        loaded = true
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            commitSave()
        }
    }

    private func commitSave() {
        let existing = store.note(for: publisherID)
        let note = ObservationNote(
            publisherID: publisherID,
            text: text,
            rating: rating,
            tags: parsedTags,
            createdAt: existing?.createdAt ?? Date(),
            modifiedAt: Date()
        )
        store.save(note)
        modifiedAt = store.note(for: publisherID)?.modifiedAt
    }

    private func clearAll() {
        saveTask?.cancel()
        text = ""
        rating = 0
        tagsInput = ""
        store.remove(publisherID: publisherID)
        modifiedAt = nil
    }

    #if os(macOS)
    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    #endif
}
