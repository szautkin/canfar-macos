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
                        editorText = WorkflowFormat.skeleton(String(localized: "Wf_NewWorkflowTitle"))
                        editorMode = .creating
                    } label: {
                        Label(String(localized: "Wf_New"), systemImage: "plus")
                    }
                    .help(String(localized: "Wf_New"))
                }
            }
        } detail: {
            if let editorMode {
                editorPane(mode: editorMode)
            } else if let item = selected {
                workflowDetail(item)
            } else {
                ContentUnavailableView(
                    String(localized: "Wf_EmptyState"),
                    systemImage: "checklist"
                )
            }
        }
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

    @ViewBuilder
    private func editorPane(mode: EditorMode) -> some View {
        VStack(alignment: .leading) {
            TextEditor(text: $editorText)
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
