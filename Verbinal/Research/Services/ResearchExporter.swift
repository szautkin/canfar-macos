// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Exports downloaded observations and astronomer notes as JSON + Markdown.
/// Notes are keyed by `publisherID` so they cross-reference cleanly with the observations file.
///
/// Lives in the Research feature module — depends on `ExportableModule` in the Export
/// module, but nothing in Export depends on the specifics of Research data.
final class ResearchExporter: ExportableModule {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ResearchExporter")
    let moduleID = "research"
    let displayName = "Research"

    private let observationStore: ObservationStore
    private let noteStore: ObservationNoteStore

    init(observationStore: ObservationStore, noteStore: ObservationNoteStore) {
        self.observationStore = observationStore
        self.noteStore = noteStore
    }

    /// Short human-readable count string, e.g. `"12 observations, 3 notes"`.
    /// Used by export feedback, notifications, and the dialog module row.
    static func itemCountLabel(observations: Int, notes: Int) -> String {
        let obs = "\(observations) observation\(observations == 1 ? "" : "s")"
        guard notes > 0 else { return obs }
        return "\(obs), \(notes) note\(notes == 1 ? "" : "s")"
    }

    func export(options: ExportOptions) async throws -> ExportModuleOutput {
        Self.logger.info("Export started: observations=\(self.observationStore.observations.count) notes=\(self.noteStore.notes.count) includeNotes=\(options.includeNotes) includeFiles=\(options.includeFileCopies)")
        var output = ExportModuleOutput()

        let encoder = ExportEncoding.jsonEncoder()

        let observations = observationStore.observations
        do {
            let obsData = try encoder.encode(observations)
            output.jsonFiles["observations.json"] = obsData
            output.itemCounts["observations"] = observations.count
        } catch {
            Self.logger.error("Observation encode failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        if options.includeNotes {
            let notes = noteStore.notes
            do {
                let notesData = try encoder.encode(notes)
                output.jsonFiles["notes.json"] = notesData
                output.itemCounts["notes"] = notes.count
            } catch {
                Self.logger.error("Notes encode failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }

            // notes.md — human/Claude readable, one section per observation with a note.
            // Walks the observations list (not notes.keys) so sections appear in the order
            // the user downloaded them, which matches the in-app sidebar order.
            let markdown = Self.renderNotesMarkdown(observations: observations, notes: notes)
            output.markdownFiles["notes.md"] = markdown
        }

        if options.includeFileCopies {
            output.attachedFiles = observations
                .filter { $0.fileExists }
                .map { URL(fileURLWithPath: $0.localPath) }
        }

        return output
    }

    /// Render notes as a single markdown document with per-observation sections.
    private static func renderNotesMarkdown(
        observations: [DownloadedObservation],
        notes: [String: ObservationNote]
    ) -> String {
        var md = "# Research Notes\n\n"
        md += "Exported \(Self.formatDate(Date())). "

        let withNotes = observations.filter { notes[$0.publisherID] != nil }
        md += "\(withNotes.count) of \(observations.count) observations have notes.\n\n"
        md += "---\n\n"

        if withNotes.isEmpty {
            md += "_No notes have been written yet._\n"
            return md
        }

        for obs in withNotes {
            guard let note = notes[obs.publisherID] else { continue }
            md += renderObservationSection(obs: obs, note: note)
        }

        return md
    }

    private static func renderObservationSection(obs: DownloadedObservation, note: ObservationNote) -> String {
        let title = obs.targetName.isEmpty ? obs.observationID : obs.targetName
        var md = "## \(title) — \(obs.collection) \(obs.observationID)\n\n"

        md += "- **Publisher ID:** `\(obs.publisherID)`\n"
        if !obs.targetName.isEmpty { md += "- **Target:** \(obs.targetName)\n" }
        md += "- **Collection:** \(obs.collection)\n"
        md += "- **Observation ID:** \(obs.observationID)\n"
        if !obs.instrument.isEmpty {
            let instrumentLine = obs.filter.isEmpty ? obs.instrument : "\(obs.instrument) / \(obs.filter)"
            md += "- **Instrument:** \(instrumentLine)\n"
        }
        if !obs.ra.isEmpty || !obs.dec.isEmpty {
            md += "- **Coordinates:** RA \(obs.ra), Dec \(obs.dec)\n"
        }
        if !obs.startDate.isEmpty {
            md += "- **Start date:** \(obs.startDate)\n"
        }
        md += "- **Downloaded:** \(formatDate(obs.downloadedAt))\n"
        if note.rating > 0 {
            md += "- **Quality:** \(starString(note.rating)) (\(qualityLabel(note.rating)))\n"
        }
        if !note.tags.isEmpty {
            let tagList = note.tags.map { "`\($0)`" }.joined(separator: ", ")
            md += "- **Tags:** \(tagList)\n"
        }
        md += "- **Note modified:** \(formatDate(note.modifiedAt))\n"

        let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            md += "\n### Notes\n\n"
            md += trimmed
            md += "\n"
        }

        md += "\n---\n\n"
        return md
    }

    private static func starString(_ n: Int) -> String {
        let filled = String(repeating: "★", count: max(0, min(5, n)))
        let empty = String(repeating: "☆", count: max(0, 5 - n))
        return filled + empty
    }

    private static func qualityLabel(_ stars: Int) -> String {
        switch stars {
        case 1: return "Unusable"
        case 2: return "Poor"
        case 3: return "Fair"
        case 4: return "Good"
        case 5: return "Excellent"
        default: return ""
        }
    }

    private static func formatDate(_ date: Date) -> String {
        ExportEncoding.iso8601.string(from: date)
    }
}
