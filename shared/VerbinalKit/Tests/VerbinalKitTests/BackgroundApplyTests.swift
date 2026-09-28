// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// An auto-applied write that outlives its call carries on as a job the
/// agent can follow, instead of looking like a timeout (Windows 1.4.1).
final class BackgroundApplyTests: XCTestCase {

    private struct SaveTool: AITool {
        static let verbClass: VerbClass = .semanticWrite
        static let agentSafe: Bool = true
        let definition = AIToolDefinition.withStaticSchema(
            name: "save_thing", description: "Saves.", schema: #"{"type":"object","properties":{}}"#)
        func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
            let proposal = await context.proposals.enqueue(PendingProposal(
                toolName: "save_thing", kind: "save_thing", summary: "Save a thing",
                payload: Data("{}".utf8), origin: context.origin))
            return .proposed(proposal)
        }
    }

    private func dispatch(applyTakes seconds: Double, fails: Bool = false, jobs: ApplyJobRegistry,
                          store: InMemoryProposalStore) async -> ToolResult {
        let hook = AutoApplyHook(
            shouldAutoApply: { _, _ in true },
            apply: { id in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if fails { throw ProposalApplyError.backendError("disk full") }
                _ = await store.markApplied(id, by: .person)
                return Data(#"{"id":"new-1"}"#.utf8)
            })
        let router = AIToolRouter(tools: [SaveTool()], auditSink: CapturingAuditSink(), autoApplyHook: hook,
                                  applyJobs: jobs, autoApplyInlineWait: 0.1)
        return await router.dispatch(
            name: "save_thing", rawArguments: Data("{}".utf8),
            context: AIToolContext(origin: .external(clientID: "t"), proposals: store, budget: ProposalBudget(limit: 8)))
    }

    private func object(_ result: ToolResult) throws -> [String: Any] {
        guard case .data(let bytes) = result else { throw XCTSkip("expected data, got \(result)") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func testAQuickApplyAnswersApplied() async throws {
        let body = try object(await dispatch(applyTakes: 0, jobs: ApplyJobRegistry(), store: InMemoryProposalStore()))
        XCTAssertEqual(body["applied"] as? Bool, true)
    }

    func testALongApplyAnswersStillApplyingThenReportsItsOutcome() async throws {
        let jobs = ApplyJobRegistry()
        let body = try object(await dispatch(applyTakes: 0.4, jobs: jobs, store: InMemoryProposalStore()))
        XCTAssertEqual(body["applied"] as? Bool, false)
        XCTAssertEqual(body["applying"] as? Bool, true)
        let id = try XCTUnwrap(UUID(uuidString: body["jobId"] as? String ?? ""))
        let running = await jobs.job(id)?.status
        XCTAssertEqual(running, .running)

        try await Task.sleep(nanoseconds: 600_000_000)
        let done = await jobs.job(id)
        XCTAssertEqual(done?.status, .succeeded)
        XCTAssertEqual(done?.result.map { String(decoding: $0, as: UTF8.self) }, #"{"id":"new-1"}"#)
    }

    func testALongApplyThatFailsIsReportedNotLost() async throws {
        let jobs = ApplyJobRegistry()
        let body = try object(await dispatch(applyTakes: 0.3, fails: true, jobs: jobs, store: InMemoryProposalStore()))
        let id = try XCTUnwrap(UUID(uuidString: body["jobId"] as? String ?? ""))
        try await Task.sleep(nanoseconds: 500_000_000)
        let job = await jobs.job(id)
        XCTAssertEqual(job?.status, .failed)
        XCTAssertTrue(job?.message?.contains("disk full") ?? false)
    }

    func testAChangeCanBeClaimedForApplyingOnlyOnce() async {
        let store = InMemoryProposalStore()
        let p = await store.enqueue(PendingProposal(toolName: "t", kind: "k", summary: "s",
                                                    payload: Data("{}".utf8), origin: .user))
        let first = await store.beginApply(p.id)
        let second = await store.beginApply(p.id)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "a second Apply while the first runs would do the work twice")
        let applying = await store.state(p.id)
        XCTAssertEqual(applying, .applying)
        _ = await store.markApplyFailed(p.id)
        let retry = await store.beginApply(p.id)
        XCTAssertTrue(retry, "a failed apply can be tried again")
        _ = await store.markApplied(p.id, by: .person)
        let applied = await store.state(p.id)
        XCTAssertEqual(applied, .applied)
    }

    func testTheRegistryKeepsABoundedHistory() async {
        let jobs = ApplyJobRegistry()
        var first: UUID?
        for i in 0..<(ApplyJobRegistry.capacity + 5) {
            let p = PendingProposal(toolName: "t", kind: "k", summary: "\(i)", payload: Data(), origin: .user)
            if first == nil { first = p.id }
            await jobs.start(p)
        }
        let oldest = await jobs.job(first!)
        XCTAssertNil(oldest)
    }
}
