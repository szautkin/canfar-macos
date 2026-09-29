import Foundation
import VerbinalKit

struct WorkflowSummaryWire: Encodable, Sendable { let id, title, description, source: String; let tags: [String]; let doneSteps, totalSteps: Int
    init(_ item: WorkflowInfo) { id = item.id; title = item.document.title; description = item.document.description; source = item.source.rawValue; tags = item.document.tags; doneSteps = item.document.doneCount; totalSteps = item.document.steps.count } }
struct WorkflowWire: Encodable, Sendable { let id, title, description, source, rawText: String; let tags: [String]; let doneSteps, totalSteps: Int; let steps: [WorkflowStep]
    init(_ item: WorkflowInfo) { id = item.id; title = item.document.title; description = item.document.description; source = item.source.rawValue; rawText = item.rawText; tags = item.document.tags; doneSteps = item.document.doneCount; totalSteps = item.document.steps.count; steps = item.document.steps } }

struct ListWorkflowsTool: JSONReadTool {
    typealias Args = EmptyArgs
    struct Output: Encodable, Sendable { let count: Int; let workflows: [WorkflowSummaryWire] }
    let definition = AIToolDefinition.withStaticSchema(name: "list_workflows", description: "List built-in workflow templates and local working copies. Templates are read-only; call use_workflow to instantiate one.", schema: #"{"type":"object","properties":{},"additionalProperties":false}"#)
    let list: @Sendable () async -> [WorkflowInfo]
    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output { let workflows = await list().map(WorkflowSummaryWire.init); return Output(count: workflows.count, workflows: workflows) }
}
struct GetWorkflowTool: JSONReadTool {
    struct Args: Decodable, Sendable { let id: String }
    let definition = AIToolDefinition.withStaticSchema(name: "get_workflow", description: "Read one workflow's structured steps, progress, and exact raw .workflow.md text.", schema: #"{"type":"object","required":["id"],"properties":{"id":{"type":"string"}},"additionalProperties":false}"#)
    let get: @Sendable (String) async -> WorkflowInfo?
    func handle(_ args: Args, context: AIToolContext) async throws -> WorkflowWire { guard let item = await get(args.id) else { throw ToolFailureReason.invalidArgument("no workflow '\(args.id)' — call list_workflows for ids") }; return WorkflowWire(item) }
}

struct SaveWorkflowTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    struct Args: Decodable, Sendable { let name, text: String; let location: String? }
    struct Payload: Codable, Sendable { let name, text: String }
    let definition = AIToolDefinition.withStaticSchema(name: "save_workflow", description: "Create a new LOCAL workflow from full .workflow.md text. `text` must include at least one checklist step (`- [ ] Title` or `- [x] Title`). VOSpace publication is not available through this tool.", schema: #"{"type":"object","required":["name","text"],"properties":{"name":{"type":"string","minLength":1},"text":{"type":"string","minLength":1,"description":"Full .workflow.md body. Must contain at least one `- [ ]` / `- [x]` checklist step."},"location":{"type":"string","enum":["local","vospace"]}},"additionalProperties":false}"#)
    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        // Reject rather than silently downgrade: reporting a local save as
        // success for a requested VOSpace publish would mislead the agent.
        if let location = args.location, location != "local" { throw ToolFailureReason.invalidArgument("location '\(location)' is not supported — this tool saves locally only (omit location or pass \"local\"); publish to VOSpace from the Workflows page") }
        guard !args.name.trimmingCharacters(in: .whitespaces).isEmpty, !args.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, WorkflowFormat.parse(args.text).steps.count > 0 else { throw ToolFailureReason.invalidArgument("name, text, and at least one `- [ ]` / `- [x]` checklist step are required") }
        return try ProposalPlan.encoding(kind: "save_workflow", summary: "Save workflow: \(args.name)", payload: Payload(name: args.name, text: args.text))
    }
}
struct UpdateWorkflowTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    struct Args: Decodable, Sendable { let id, text: String }; struct Payload: Codable, Sendable { let id, text: String }
    let definition = AIToolDefinition.withStaticSchema(name: "update_workflow", description: "Replace the raw text of a LOCAL workflow.", schema: #"{"type":"object","required":["id","text"],"properties":{"id":{"type":"string"},"text":{"type":"string","minLength":1}},"additionalProperties":false}"#)
    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan { guard args.id.hasPrefix(WorkflowStore.localPrefix), !args.text.isEmpty else { throw ToolFailureReason.invalidArgument("id must be local:… and text is required") }; return try ProposalPlan.encoding(kind: "update_workflow", summary: "Update workflow \(args.id)", payload: Payload(id: args.id, text: args.text)) }
}
struct SetWorkflowStepTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    struct Args: Decodable, Sendable { let id: String; let index: Int; let done: Bool? }; struct Payload: Codable, Sendable { let id: String; let index: Int; let done: Bool }
    let definition = AIToolDefinition.withStaticSchema(name: "set_workflow_step", description: "Mark a LOCAL workflow step done or not done by 0-based index.", schema: #"{"type":"object","required":["id","index"],"properties":{"id":{"type":"string"},"index":{"type":"integer","minimum":0},"done":{"type":"boolean"}},"additionalProperties":false}"#)
    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan { guard args.index >= 0 else { throw ToolFailureReason.invalidArgument("index must be >= 0") }; return try ProposalPlan.encoding(kind: "set_workflow_step", summary: "Update workflow step \(args.index + 1)", payload: Payload(id: args.id, index: args.index, done: args.done ?? true)) }
}
struct UseWorkflowTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    struct Args: Decodable, Sendable { let id: String; let name: String? }; struct Payload: Codable, Sendable { let id: String; let name: String? }
    let definition = AIToolDefinition.withStaticSchema(name: "use_workflow", description: "Copy a template or workflow into a new LOCAL working copy that can track progress — a new copy every time, numbered when its title is taken (\"… (2)\"); the answer's `id` is the copy's.", schema: #"{"type":"object","required":["id"],"properties":{"id":{"type":"string"},"name":{"type":"string"}},"additionalProperties":false}"#)
    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan { try ProposalPlan.encoding(kind: "use_workflow", summary: "Use workflow \(args.id)", payload: Payload(id: args.id, name: args.name)) }
}
struct DeleteWorkflowTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive
    struct Args: Decodable, Sendable { let id: String }; struct Payload: Codable, Sendable { let id: String }
    let definition = AIToolDefinition.withStaticSchema(name: "delete_workflow", description: "Delete a LOCAL workflow including its tracked progress.", schema: #"{"type":"object","required":["id"],"properties":{"id":{"type":"string"}},"additionalProperties":false}"#)
    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan { guard args.id.hasPrefix(WorkflowStore.localPrefix) else { throw ToolFailureReason.invalidArgument("id must be a local:… workflow") }; return try ProposalPlan.encoding(kind: "delete_workflow", summary: "Delete workflow \(args.id)", payload: Payload(id: args.id)) }
}

/// A workflow's changes; a new copy's id comes back in the answer — the
/// copy `use_workflow` or `save_workflow` made (plan 19 S2, QA N17).
struct WorkflowApplier: ProposalApplier, ResultReportingApplier {
    let kind: String; let store: WorkflowStore; let activity: AgentActivityStore
    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }
    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let made: String? = try await MainActor.run {
            // Robot-badge provenance: agent-created working copies carry the
            // same attribution stamp as saved queries / notes / downloads.
            let attribution = AgentAttribution.from(proposal: proposal)
            let made: String?
            switch kind {
            case "save_workflow": let p = try JSONDecoder().decode(SaveWorkflowTool.Payload.self, from: proposal.payload); made = try store.saveNew(name: p.name, text: p.text, attribution: attribution)
            case "update_workflow": let p = try JSONDecoder().decode(UpdateWorkflowTool.Payload.self, from: proposal.payload); try store.updateText(p.id, text: p.text); made = nil
            case "set_workflow_step": let p = try JSONDecoder().decode(SetWorkflowStepTool.Payload.self, from: proposal.payload); try store.setStepDone(p.id, index: p.index, done: p.done); made = nil
            case "use_workflow": let p = try JSONDecoder().decode(UseWorkflowTool.Payload.self, from: proposal.payload); made = try store.useWorkflow(p.id, name: p.name, attribution: attribution)
            case "delete_workflow": let p = try JSONDecoder().decode(DeleteWorkflowTool.Payload.self, from: proposal.payload); try store.delete(p.id); made = nil
            // A kind we're registered for but don't handle means the switch
            // and the registration list in AppState+AgentTools drifted —
            // fail loudly rather than mark the proposal applied.
            default: throw ProposalApplyError.backendError("WorkflowApplier has no handler for kind '\(kind)'")
            }
            activity.append(.applied(proposal: proposal, kind: kind))
            return made
        }
        return (try? JSONEncoder().encode(AutoAppliedAck.Extra(id: made))) ?? Data()
    }
}
