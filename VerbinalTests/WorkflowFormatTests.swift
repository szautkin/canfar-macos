import XCTest
import VerbinalKit
@testable import Verbinal

final class WorkflowFormatTests: XCTestCase {
    func testParsesWindowsChecklistDialect() {
        let document = WorkflowFormat.parse("# Plan\n> Desc\nTags: one, two\n- [x] **First** — Body\n  Tool: get_workflow\n  View: workflows\n")
        XCTAssertEqual(document.title, "Plan")
        XCTAssertEqual(document.tags, ["one", "two"])
        XCTAssertEqual(document.steps.first?.title, "First")
        XCTAssertTrue(document.steps.first!.done)
        XCTAssertTrue(document.warnings.isEmpty)
    }

    func testSkeletonHasTitleAndStepsWithoutWarnings() {
        let text = WorkflowFormat.skeleton("New workflow")
        let document = WorkflowFormat.parse(text)
        XCTAssertEqual(document.title, "New workflow")
        XCTAssertFalse(document.steps.isEmpty)
        XCTAssertTrue(document.warnings.isEmpty)
    }

    func testMissingTitleAndStepsProduceWarnings() {
        let document = WorkflowFormat.parse("Tags: alone\n")
        XCTAssertEqual(document.title, "Untitled workflow")
        XCTAssertTrue(document.steps.isEmpty)
        XCTAssertEqual(document.warnings.count, 2)
    }

    func testCheckboxFlipPreservesCRLFBytes() throws {
        let original = "# Plan\r\n- [ ] **One**\r\n- [x] **Two**\r\n"
        let changed = try WorkflowFormat.withStepDone(original, stepIndex: 0, done: true)
        XCTAssertEqual(changed, "# Plan\r\n- [x] **One**\r\n- [x] **Two**\r\n")
    }

    @MainActor func testStoreCopiesTemplateAndTracksStep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory, builtins: { [("sample", "# Sample\n- [ ] **Step**\n")] })
        let id = try store.useWorkflow("builtin:sample")
        try store.setStepDone(id, index: 0, done: true)
        XCTAssertEqual(store.get(id)?.document.doneCount, 1)
    }

    @MainActor func testStoreUpdateTextAndDeleteLocal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory, builtins: { [] })
        let id = try store.saveNew(name: "Draft", text: "# Draft\n- [ ] **One**\n")
        try store.updateText(id, text: "# Revised\n- [x] **One**\n- [ ] **Two**\n")
        let updated = try XCTUnwrap(store.get(id))
        XCTAssertEqual(updated.document.title, "Revised")
        XCTAssertEqual(updated.document.steps.count, 2)
        XCTAssertEqual(updated.document.doneCount, 1)
        try store.delete(id)
        XCTAssertNil(store.get(id))
        XCTAssertTrue(store.listLocal().isEmpty)
    }

    @MainActor func testAgentAttributionSidecarRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory, builtins: { [] })
        let attribution = AgentAttribution(
            proposalID: UUID(), originFingerprint: "abc123",
            originLabel: "claude-ai/0.1.0", appliedAt: Date(), summary: "Save workflow: Robot")

        let id = try store.saveNew(name: "Robot", text: "# Robot\n- [ ] **Step**\n", attribution: attribution)
        XCTAssertEqual(store.get(id)?.agentAttribution?.originLabel, "claude-ai/0.1.0")
        XCTAssertEqual(store.listLocal().first?.agentAttribution?.originFingerprint, "abc123")
        // The .workflow.md bytes stay clean — attribution lives in the sidecar only.
        let raw = store.get(id)!.rawText
        XCTAssertFalse(raw.contains("claude-ai"))

        // User-authored copies carry no badge.
        let plain = try store.saveNew(name: "Mine", text: "# Mine\n- [ ] **Step**\n")
        XCTAssertNil(store.get(plain)?.agentAttribution)

        // Deleting the workflow scrubs its sidecar entry.
        try store.delete(id)
        XCTAssertFalse(store.listLocal().contains { $0.agentAttribution != nil })
    }

    func testWorkflowToolsUseWindowsWireNames() {
        XCTAssertEqual(
            [
                ListWorkflowsTool(list: { [] }).definition.name,
                GetWorkflowTool(get: { _ in nil }).definition.name,
                SaveWorkflowTool().definition.name,
                UpdateWorkflowTool().definition.name,
                SetWorkflowStepTool().definition.name,
                UseWorkflowTool().definition.name,
                DeleteWorkflowTool().definition.name,
            ],
            ["list_workflows", "get_workflow", "save_workflow", "update_workflow",
             "set_workflow_step", "use_workflow", "delete_workflow"]
        )
    }

    func testSaveWorkflowPlanRequiresChecklistStep() async {
        let ctx = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 8)
        )
        do {
            _ = try await SaveWorkflowTool().plan(
                .init(name: "Notes", text: "# Notes\nJust a document.", location: nil),
                context: ctx)
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument(let msg) = f else {
                return XCTFail("wrong case: \(f)")
            }
            XCTAssertTrue(msg.contains("- [ ]"), "must name the checklist syntax; got \(msg)")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testSaveWorkflowPlanAcceptsChecklist() async throws {
        let ctx = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 8)
        )
        let plan = try await SaveWorkflowTool().plan(
            .init(name: "Plan", text: "# Plan\n- [ ] **Step**\n", location: nil),
            context: ctx)
        XCTAssertEqual(plan.kind, "save_workflow")
    }
}
