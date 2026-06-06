// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// Modal to create or edit a custom guide tool — a user-authored, read-only
/// "instruction tool". `name` becomes the agent-facing tool name (shown as a
/// live-sanitized slug), `description` is what the agent reads in `tools/list`,
/// and `body` (optional) is the text returned when the agent calls the tool.
struct AIGuideEntryEditSheet: View {
    enum Mode {
        case create
        case edit(AIGuideToolEntry)
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var name = ""
    @State private var descriptionText = ""
    @State private var instructions = ""
    @State private var error: String?

    private var service: AIGuideService { appState.aiGuideService }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }
    private var editingID: UUID? {
        if case .edit(let entry) = mode { return entry.id }
        return nil
    }
    private var previewSlug: String { AIGuideService.slug(name) }
    private var descriptionTrimmed: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool {
        !previewSlug.isEmpty
        && !descriptionTrimmed.isEmpty
        && descriptionText.count <= AIGuideService.maxDescriptionChars
        && instructions.count <= AIGuideService.maxBodyChars
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEdit ? "Edit Guide Tool" : "New Guide Tool")
                .font(.headline)

            // Name + live slug preview
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: $name, prompt: Text("e.g. Batch Download Strategy"))
                    .textFieldStyle(.roundedBorder)
                if previewSlug.isEmpty {
                    Text("Use letters, numbers, spaces, or underscores.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The agent calls this as ").font(.caption2).foregroundColor(.secondary)
                    + Text(previewSlug).font(.system(.caption2, design: .monospaced)).foregroundColor(.primary)
                }
            }

            // Description (tools/list)
            VStack(alignment: .leading, spacing: 3) {
                Text("Description — what the agent reads in the tool list")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $descriptionText)
                    .font(.callout)
                    .frame(height: 54)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("\(descriptionText.count)/\(AIGuideService.maxDescriptionChars)")
                    .font(.caption2)
                    .foregroundStyle(descriptionText.count > AIGuideService.maxDescriptionChars ? .red : .secondary)
            }

            // Body (returned on call)
            VStack(alignment: .leading, spacing: 3) {
                Text("Instructions — returned when the agent calls this tool")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $instructions)
                    .font(.callout)
                    .frame(height: 150)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("\(instructions.count)/\(AIGuideService.maxBodyChars) — optional; if blank, the description is returned")
                    .font(.caption2)
                    .foregroundStyle(instructions.count > AIGuideService.maxBodyChars ? .red : .secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isEdit {
                    Button("Delete", role: .destructive) {
                        if let id = editingID { service.deleteGuide(id: id) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            if case .edit(let entry) = mode {
                name = entry.name
                descriptionText = entry.description
                instructions = entry.body ?? ""
            }
        }
    }

    private func save() {
        let body = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyOrNil = body.isEmpty ? nil : body
        do {
            if let id = editingID {
                try service.updateGuide(id: id, name: name, description: descriptionText, body: bodyOrNil)
            } else {
                try service.addGuide(name: name, description: descriptionText, body: bodyOrNil)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
