import XCTest
@testable import Verbinal

final class WorkflowFormatTests: XCTestCase {
    func testParsesWindowsChecklistDialect() {
        let document = WorkflowFormat.parse("# Plan\n> Desc\nTags: one, two\n- [x] **First** — Body\n  Tool: get_workflow\n  View: workflows\n")
        XCTAssertEqual(document.title, "Plan")
        XCTAssertEqual(document.tags, ["one", "two"])
        XCTAssertEqual(document.steps.first?.title, "First")
        XCTAssertTrue(document.steps.first!.done)
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
}
