// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 42 step 3: what an assistant is told about GPUs — the brief, each
/// tool's own words, the built-in workflows — says what the tools do.
final class GuidesGPUTests: XCTestCase {

    // MARK: - describe_app

    func testTheBriefSaysHowGPUsAreAsked() {
        let brief = DescribeAppTool.brief
        XCTAssertTrue(brief.contains("## GPUs"))
        for words in ["`get_platform_load`", "`perSession`", "`gpuNote`", "`gpu.free`", "`launch_session`",
                      "`launch_headless_job`", "`show_launch_form`", "Standard", "Advanced", "Headless", "0, or one of"] {
            XCTAssertTrue(brief.contains(words), "the brief's GPUs: \(words)")
        }
    }

    /// The brief had said an omitted size took Skaha's 2/8/0, which
    /// launch_headless_job has not done since plan 15: it forces 1/1/0.
    func testTheBriefSaysWhatAnOmittedBatchSizeIs() {
        XCTAssertFalse(DescribeAppTool.brief.contains("inherits Skaha's 2/8/0"))
        XCTAssertTrue(DescribeAppTool.brief.contains("omitting `cores`/`ram`/`gpus` gives 1/1/0"))
    }

    // MARK: - The tools' own words, and what they do

    private func gpusDescription(_ definition: AIToolDefinition) -> String? {
        guard case .object(let schema) = definition.inputSchema, case .object(let properties)? = schema["properties"],
              case .object(let gpus)? = properties["gpus"], case .string(let text)? = gpus["description"] else { return nil }
        return text
    }

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
    }

    private let staging = GPUOffer(options: Array(1...7))

    /// launch_session's words — 0, or one of the counts offered — and what
    /// its plan takes and refuses.
    func testLaunchSessionSaysWhatItTakes() async throws {
        let tool = LaunchSessionTool(offer: { [staging] in staging })
        XCTAssertEqual(gpusDescription(tool.definition), "0, or one of the counts the platform offers.")
        XCTAssertTrue(tool.definition.description.contains("get_platform_load"))
        let args = { (gpus: Int) in LaunchSessionTool.Args(type: "contributed", name: "n", image: "images.canfar.net/me/llm:1", gpus: gpus) }
        _ = try await tool.plan(args(7), context: ctx())
        do {
            _ = try await tool.plan(args(8), context: ctx())
            XCTFail("8 is not offered")
        } catch ToolFailureReason.invalidArgument {}
    }

    func testLaunchHeadlessJobSaysWhatItTakes() async throws {
        let tool = LaunchHeadlessJobTool(offer: { [staging] in staging })
        let words = try XCTUnwrap(gpusDescription(tool.definition))
        XCTAssertTrue(words.hasPrefix("GPU count: 0, or one the platform offers"), words)
        XCTAssertTrue(words.contains("get_platform_load"), words)
        let args = { (gpus: Int) in
            LaunchHeadlessJobTool.Args(name: "j", image: "images.canfar.net/skaha/terminal:1.1.2", cmd: "nvidia-smi", gpus: gpus)
        }
        _ = try await tool.plan(args(7), context: ctx())
        do {
            _ = try await tool.plan(args(8), context: ctx())
            XCTFail("8 is not offered")
        } catch ToolFailureReason.invalidArgument {}
    }

    /// show_launch_form judges by its tab: its words say so.
    func testShowLaunchFormSaysItJudgesByTab() throws {
        let tool = ShowLaunchFormTool(show: { _ in LaunchFormShown(shown: false, tab: nil, image: nil, imageSource: nil) })
        let words = try XCTUnwrap(gpusDescription(tool.definition))
        XCTAssertTrue(words.contains("standard") && words.contains("advanced"), words)
        XCTAssertTrue(words.contains("0 or 1"), words)
    }

    // MARK: - The built-in workflows

    @MainActor
    func testTheBatchWorkflowsSayHowToAskForGPUs() throws {
        let store = WorkflowStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID().uuidString)"))
        let all = store.listBuiltIn()
        for id in ["builtin:canfar-batch-reprocessing", "builtin:canfar-survey-to-candidates"] {
            let workflow = try XCTUnwrap(all.first { $0.id == id }, "\(all.map(\.id))")
            XCTAssertEqual(workflow.document.warnings, [], id)
            let launching = workflow.document.steps.filter { $0.tools.contains("launch_headless_job") }
            XCTAssertFalse(launching.isEmpty, id)
            XCTAssertTrue(launching.contains { ($0.note ?? "").contains("get_platform_load") }, "\(id): a launch step says where GPUs are")
        }
    }
}
