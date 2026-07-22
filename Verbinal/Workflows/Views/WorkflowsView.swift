import SwiftUI

struct WorkflowsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedID: String?
    @State private var editorText = ""
    @State private var editing = false

    private var store: WorkflowStore { appState.workflowStore }
    private var selected: WorkflowInfo? { selectedID.flatMap(store.get) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section(String(localized: "Wf_TemplatesHeader")) {
                    ForEach(store.listBuiltIn()) { item in Text(item.document.title).tag(item.id) }
                }
                Section(String(localized: "Wf_MyWorkflowsHeader")) {
                    ForEach(store.listLocal()) { item in
                        Text("\(item.document.title) (\(item.document.doneCount)/\(item.document.steps.count))").tag(item.id)
                    }
                }
            }
            .navigationTitle(String(localized: "Wf_PageTitle"))
            .toolbar { Button { editorText = WorkflowFormat.skeleton(String(localized: "Wf_NewWorkflowTitle")); editing = true } label: { Image(systemName: "plus") } }
        } detail: {
            if editing {
                VStack(alignment: .leading) {
                    TextEditor(text: $editorText).fontDesign(.monospaced)
                    HStack {
                        Button(String(localized: "Wf_Save")) { let doc = WorkflowFormat.parse(editorText); selectedID = try? store.saveNew(name: doc.title, text: editorText); editing = false }
                        Button(String(localized: "Wf_Cancel")) { editing = false }
                    }
                }.padding()
            } else if let item = selected {
                workflowDetail(item)
            } else {
                ContentUnavailableView(String(localized: "Wf_EmptyState"), systemImage: "checklist")
            }
        }
    }
    private func workflowDetail(_ item: WorkflowInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.document.title).font(.title.bold())
                if !item.document.description.isEmpty { Text(item.document.description).foregroundStyle(.secondary) }
                ProgressView(value: Double(item.document.doneCount), total: Double(max(1, item.document.steps.count)))
                ForEach(item.document.steps) { step in
                    Button {
                        guard item.source == .local else { return }
                        try? store.setStepDone(item.id, index: step.index, done: !step.done)
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(step.title).strikethrough(step.done)
                                if !step.body.isEmpty { Text(step.body).font(.callout).foregroundStyle(.secondary) }
                                if !step.tools.isEmpty { Text(step.tools.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.tint) }
                            }
                        }
                    }.buttonStyle(.plain).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                if item.source == .builtIn { Button(String(localized: "Wf_Use")) { selectedID = try? store.useWorkflow(item.id) }.buttonStyle(.borderedProminent) }
            }.padding()
        }
    }
}
