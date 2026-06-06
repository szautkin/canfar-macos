// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// Shared presentation for a single built-in tool. Used both as a divided row
/// inside ``AIGuideCategoryCard`` (`categoryTitle == nil`) and, with the
/// category surfaced as a subtitle, inside ``AIGuideToolCard`` for flat search
/// results (`categoryTitle != nil`).
///
/// Editing is an **inline accordion**: tapping Edit expands the row in place
/// (the host's `VStack`/`LazyVGrid` reflows, pushing siblings down) to reveal
/// the built-in-default reference, a `TextEditor`, a live char count, and
/// Save / Reset / Cancel — no modal. The expanded-or-not decision is owned by
/// the host via `editingToolName`, which gives strict one-at-a-time-per-host
/// for free: opening a sibling collapses this one. The draft text and inline
/// error are row-local `@State` so they die on collapse. The row never touches
/// `AIGuideService`; persistence flows through `onSave`/`onReset` closures, so
/// all three hosts behave identically.
///
/// Keeping the overridden capsule and the right-click reset context menu here
/// means both call sites stay byte-identical and the overridden affordance is
/// impossible to drift between them.
struct AIGuideToolRow: View {
    let row: AIGuideTool
    /// Non-nil only in flat search mode; rendered as a subtitle under the name.
    let categoryTitle: String?
    /// Host-owned edit target. The row is expanded iff `editingToolName == row.name`.
    @Binding var editingToolName: String?
    /// Persist an override; returns `nil` on success, else a user-facing error
    /// string to surface inline. The host owns the throwing→String adapter.
    let onSave: (_ toolName: String, _ description: String) -> String?
    /// Clear the override (inline Reset button + right-click context menu).
    let onReset: () -> Void

    /// Ephemeral edit buffer — seeded on expand, deinits on collapse.
    @State private var draft: String = ""
    /// Inline validation error from the last failed save (e.g. over cap).
    @State private var inlineError: String?
    @FocusState private var editorFocused: Bool
    /// Where keyboard focus returns when the editor collapses (Save/Cancel/Reset)
    /// so a keyboard/VoiceOver user is not stranded after committing.
    @FocusState private var editButtonFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isEditing: Bool { editingToolName == row.name }
    /// Validate against the trimmed value — `setOverride` trims before its cap
    /// check, so counting raw chars would falsely disable Save on trailing space.
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var overLimit: Bool { trimmedDraft.count > AIGuideService.maxDescriptionChars }
    /// Saving an empty value clears the override — say so on the button.
    private var saveLabel: String { (trimmedDraft.isEmpty && row.isOverridden) ? "Clear Override" : "Save" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isEditing {
                editor
            } else {
                collapsedDescription
            }
        }
        .padding(.vertical, 2)
        .animation(reduceMotion ? nil : AppMotion.expand, value: isEditing)
        .contextMenu {
            if row.isOverridden {
                Button("Reset to Default", action: onReset)
            }
        }
    }

    // MARK: - Header (always visible; never moves)

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isOverridden {
                        Text("overridden")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(.tint)
                            .accessibilityLabel("overridden")
                    }
                }
                if let categoryTitle {
                    Text(categoryTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(isEditing ? "Cancel" : "Edit") {
                if isEditing { cancel() } else { beginEdit() }
            }
            .controlSize(.small)
            .focused($editButtonFocused)
            .accessibilityLabel(isEditing ? "Cancel editing \(row.name)" : "Edit \(row.name)")
        }
    }

    // MARK: - Collapsed description (shown only when not editing)

    private var collapsedDescription: some View {
        Text(row.effectiveDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)   // clamp; full text lives in the inline editor
            .fixedSize(horizontal: false, vertical: true)
            .help(row.effectiveDescription)
    }

    // MARK: - Inline editor (shown only when editing)

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-in default")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.defaultDescription)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.4)))

            Text("Your description")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.callout)
                .frame(minHeight: 96, maxHeight: 160)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .focused($editorFocused)

            HStack {
                Text("\(trimmedDraft.count)/\(AIGuideService.maxDescriptionChars)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(overLimit ? .red : .secondary)
                if let inlineError {
                    Label(inlineError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                if row.isOverridden {
                    Button("Reset to Default", role: .destructive, action: reset)
                        .help("Remove the override and restore the built-in description.")
                }
                Button(saveLabel, action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(overLimit)
            }
        }
        // Esc cancels the inline edit; this handler exists only while editing, so
        // it shadows the focus panel's outer `.onExitCommand { close() }` via
        // innermost-responder-first dispatch and leaves the panel open. When no
        // row edits, it is absent and Esc falls through to close the panel.
        .onExitCommand { cancel() }
        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
        // Group the live counter + reference so VoiceOver reads them once, not
        // per keystroke.
        .accessibilityElement(children: .contain)
        .onAppear {
            draft = row.effectiveDescription
            // Setting @FocusState before the focused view mounts is a silent
            // no-op, so hop one runloop tick first (mirrors AIGuideView.open()).
            DispatchQueue.main.async { editorFocused = true }
            AccessibilityNotification.Announcement("Editing \(row.name).").post()
        }
    }

    // MARK: - Actions

    private func beginEdit() {
        inlineError = nil
        editingToolName = row.name
    }

    private func cancel() { collapse() }

    private func save() {
        if let error = onSave(row.name, draft) {
            inlineError = error   // keep the editor open so the user can fix it
        } else {
            collapse()
        }
    }

    private func reset() {
        onReset()
        collapse()
    }

    /// Collapse the editor and return keyboard focus to this row's Edit button,
    /// so a keyboard/VoiceOver user lands somewhere deterministic after committing
    /// (instead of focus being dropped to nowhere).
    private func collapse() {
        editingToolName = nil
        DispatchQueue.main.async { editButtonFocused = true }
        AccessibilityNotification.Announcement("Closed editor for \(row.name).").post()
    }
}
#endif
