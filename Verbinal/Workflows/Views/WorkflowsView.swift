// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct WorkflowsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedID: String?
    @State private var editorText = ""
    /// `nil` while browsing; set while creating or editing markdown.
    @State private var editorMode: EditorMode?
    @State private var workflowPendingDelete: WorkflowInfo?

    private enum EditorMode: Equatable {
        case creating
        case editing(id: String)
    }

    private var store: WorkflowStore { appState.workflowStore }
    private var selected: WorkflowInfo? { selectedID.flatMap(store.get) }

    /// Advisory parse issues for the live editor (localized; not hard-blocks).
    private var editorWarnings: [String] {
        let doc = WorkflowFormat.parse(editorText)
        var messages: [String] = []
        let hasTitleLine = editorText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("# ") && !t.hasPrefix("##")
            }
        if !hasTitleLine {
            messages.append(String(localized: "Wf_Warn_NoTitle"))
        }
        if doc.steps.isEmpty {
            messages.append(String(localized: "Wf_Warn_NoSteps"))
        }
        return messages
    }

    var body: some View {
        // Touch changeID so check-off / save / delete refresh the split view.
        let _ = store.changeID
        NavigationSplitView {
            List(selection: $selectedID) {
                Section(String(localized: "Wf_TemplatesHeader")) {
                    ForEach(store.listBuiltIn()) { item in
                        Text(item.document.title).tag(item.id)
                    }
                }
                Section(String(localized: "Wf_MyWorkflowsHeader")) {
                    ForEach(store.listLocal()) { item in
                        HStack(spacing: 5) {
                            #if os(macOS)
                            if let attribution = item.agentAttribution {
                                AgentAttributionBadge(attribution: attribution)
                            }
                            #endif
                            Text("\(item.document.title) (\(item.document.doneCount)/\(item.document.steps.count))")
                        }
                        .tag(item.id)
                    }
                }
            }
            .navigationTitle(String(localized: "Wf_PageTitle"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startCreating()
                    } label: {
                        Label(String(localized: "Wf_New"), systemImage: "plus")
                    }
                    .help(String(localized: "Wf_New"))
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        selectedID = nil
                    } label: {
                        Label(String(localized: "Wf_ClearSelection"), systemImage: "sidebar.squares.left")
                    }
                    .help(String(localized: "Wf_ClearSelection"))
                    .disabled(selectedID == nil || editorMode != nil)
                }
            }
        } detail: {
            if let editorMode {
                editorPane(mode: editorMode)
            } else if let item = selected {
                workflowDetail(item)
            } else {
                emptyOverview
            }
        }
        .uiPresented("Delete the Workflow?", .confirmation, item: $workflowPendingDelete)
        .confirmationDialog(
            String(localized: "Wf_DeleteConfirmTitle"),
            isPresented: Binding(
                get: { workflowPendingDelete != nil },
                set: { if !$0 { workflowPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Wf_Delete"), role: .destructive) {
                guard let item = workflowPendingDelete else { return }
                try? store.delete(item.id)
                if selectedID == item.id { selectedID = nil }
                workflowPendingDelete = nil
            }
            Button(String(localized: "Wf_Cancel"), role: .cancel) {
                workflowPendingDelete = nil
            }
        } message: {
            if let item = workflowPendingDelete {
                Text(
                    String(
                        format: String(localized: "Wf_DeleteConfirmMessage"),
                        item.document.title
                    )
                )
            }
        }
    }

    private var emptyOverview: some View {
        ContentUnavailableView {
            Label(String(localized: "Wf_EmptyState"), systemImage: "checklist")
        } description: {
            Text(String(localized: "Wf_EmptyStateDescription"))
        } actions: {
            Button {
                startCreating()
            } label: {
                Label(String(localized: "Wf_New"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Opens the create editor from overview intent: clear list selection so
    /// Cancel returns to the empty workarea, not a previously selected detail.
    private func startCreating() {
        selectedID = nil
        editorText = WorkflowFormat.skeleton(String(localized: "Wf_NewWorkflowTitle"))
        editorMode = .creating
    }

    @ViewBuilder
    private func editorPane(mode: EditorMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    mode == .creating
                        ? String(localized: "Wf_EditorCreatingTitle")
                        : String(localized: "Wf_EditorEditingTitle")
                )
                .font(.headline)

                Text(String(localized: "Wf_FormatHint_Intro"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    formatHintRow(String(localized: "Wf_FormatHint_Title"))
                    formatHintRow(String(localized: "Wf_FormatHint_Description"))
                    formatHintRow(String(localized: "Wf_FormatHint_Steps"))
                    formatHintRow(String(localized: "Wf_FormatHint_Attachments"))
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                if !editorWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(editorWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            TextEditor(text: $editorText)
                .textEditorName(String(localized: "Workflow text"))
                .fontDesign(.monospaced)
            HStack {
                Button(String(localized: "Wf_Save")) {
                    saveEditor(mode: mode)
                }
                .keyboardShortcut(.defaultAction)
                Button(String(localized: "Wf_Cancel")) {
                    editorMode = nil
                }
            }
        }
        .padding()
    }

    private func formatHintRow(_ text: String) -> some View {
        Text("• \(text)")
    }

    private func saveEditor(mode: EditorMode) {
        let doc = WorkflowFormat.parse(editorText)
        switch mode {
        case .creating:
            selectedID = try? store.saveNew(name: doc.title, text: editorText)
        case .editing(let id):
            try? store.updateText(id, text: editorText)
            selectedID = id
        }
        editorMode = nil
    }

    private func workflowDetail(_ item: WorkflowInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(item.document.title).font(.title.bold())
                    #if os(macOS)
                    if let attribution = item.agentAttribution {
                        AgentAttributionBadge(attribution: attribution)
                    }
                    #endif
                    Spacer(minLength: 8)
                    Button {
                        selectedID = nil
                    } label: {
                        Text(String(localized: "Wf_ClearSelection"))
                    }
                    .help(String(localized: "Wf_ClearSelection"))
                    if item.source == .local {
                        Button(String(localized: "Wf_Edit")) {
                            editorText = item.rawText
                            editorMode = .editing(id: item.id)
                        }
                        Button(String(localized: "Wf_Delete"), role: .destructive) {
                            workflowPendingDelete = item
                        }
                    }
                }
                if !item.document.description.isEmpty {
                    Text(item.document.description).foregroundStyle(.secondary)
                }
                ProgressView(
                    value: Double(item.document.doneCount),
                    total: Double(max(1, item.document.steps.count))
                )
                ForEach(item.document.steps) { step in
                    Button {
                        guard item.source == .local else { return }
                        try? store.setStepDone(item.id, index: step.index, done: !step.done)
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(step.title).strikethrough(step.done)
                                if !step.body.isEmpty {
                                    Text(step.body)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                if !step.tools.isEmpty {
                                    Text(step.tools.joined(separator: ", "))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                if item.source == .builtIn {
                    Button(String(localized: "Wf_Use")) {
                        selectedID = try? store.useWorkflow(item.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }
}
