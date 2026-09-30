// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import XCTest
@testable import VerbinalKit

/// Plan 23 K: who and why travel with the work, and every write says why.
final class CauseTests: XCTestCase {

    /// A write that notes the cause it planned under.
    private struct DeleteThing: JSONWriteTool {
        static let verbClass: VerbClass = .destructive
        struct Args: Decodable, Sendable { let id: String }
        let seen: CauseBox
        let definition = AIToolDefinition.withStaticSchema(
            name: "delete_thing", description: "Deletes a thing.",
            schema: #"{"type":"object","required":["id"],"properties":{"id":{"type":"string"}},"additionalProperties":false}"#)

        func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
            seen.cause = Cause.current
            return ProposalPlan(kind: "delete_thing", summary: "Delete \(args.id)", payload: Data())
        }
    }

    private struct ReadThing: JSONReadTool {
        struct Args: Decodable, Sendable {}
        struct Output: Encodable, Sendable { let ok = true }
        let definition = AIToolDefinition.withStaticSchema(
            name: "read_thing", description: "Reads a thing.",
            schema: #"{"type":"object","properties":{},"additionalProperties":false}"#)
        func handle(_ args: Args, context: AIToolContext) async throws -> Output { Output() }
    }

    private final class CauseBox: @unchecked Sendable {
        var cause: Cause?
    }

    private func context(session: UUID? = UUID(), store: InMemoryProposalStore = InMemoryProposalStore()) -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test/1"), proposals: store, budget: ProposalBudget(), session: session)
    }

    // MARK: - The published schema

    func testEveryWriteToolIsPublishedWithWhyAndNoReadTool() async throws {
        let router = AIToolRouter(tools: [DeleteThing(seen: CauseBox()), ReadThing()], auditSink: CapturingAuditSink())
        let tools = await PublishedManifest.tools(router: router, aiGuide: nil)
        func properties(_ name: String) throws -> [String: JSONValue] {
            let tool = try XCTUnwrap(tools.first { $0.name == name })
            guard case .object(let root) = tool.inputSchema, case .object(let properties)? = root["properties"] else {
                XCTFail("\(name) has no properties"); return [:]
            }
            return properties
        }
        XCTAssertNotNil(try properties("delete_thing")["why"])
        XCTAssertNotNil(try properties("delete_thing")["id"], "the tool's own arguments stay")
        XCTAssertNil(try properties("read_thing")["why"])
    }

    func testOnlyChangesTakeWhy() {
        XCTAssertTrue(VerbClass.semanticWrite.proposesChange)
        XCTAssertTrue(VerbClass.destructive.proposesChange)
        XCTAssertTrue(VerbClass.standingInstruction.proposesChange)
        XCTAssertFalse(VerbClass.read.proposesChange)
        XCTAssertFalse(VerbClass.viewState.proposesChange)
        XCTAssertFalse(VerbClass.proposalLifecycle.proposesChange)
    }

    // MARK: - The router takes it

    /// `why` is off the arguments before the tool's own check (which
    /// allows no other property), on the proposal, and the call's cause.
    func testTheRouterTakesWhyOffAndMakesItTheCause() async throws {
        let seen = CauseBox()
        let store = InMemoryProposalStore()
        let router = AIToolRouter(tools: [DeleteThing(seen: seen)], auditSink: CapturingAuditSink())
        let context = context(store: store)
        let result = await router.dispatch(
            name: "delete_thing", rawArguments: Data(#"{"id":"q9p87ajc","why":"  throwaway from the QA pass  "}"#.utf8),
            context: context)
        guard case .proposed(let proposal) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(proposal.why, "throwaway from the QA pass")
        XCTAssertEqual(proposal.session, context.session)
        XCTAssertEqual(seen.cause?.why, "throwaway from the QA pass")
        XCTAssertEqual(seen.cause?.call, context.requestID)
        XCTAssertEqual(seen.cause?.session, context.session)
    }

    func testAWriteWithoutWhyStillWorks() async {
        let router = AIToolRouter(tools: [DeleteThing(seen: CauseBox())], auditSink: CapturingAuditSink())
        let result = await router.dispatch(name: "delete_thing", rawArguments: Data(#"{"id":"x"}"#.utf8), context: context())
        guard case .proposed(let proposal) = result else { return XCTFail("\(result)") }
        XCTAssertNil(proposal.why)
    }

    func testAReadDoesNotTakeWhy() async {
        let router = AIToolRouter(tools: [ReadThing()], auditSink: CapturingAuditSink())
        let result = await router.dispatch(name: "read_thing", rawArguments: Data(#"{"why":"because"}"#.utf8), context: context())
        guard case .failed(.invalidArgument) = result else { return XCTFail("a read has no why: \(result)") }
    }

    // MARK: - Kept, and clipped

    func testAReasonIsKeptOnTheProposalAcrossARelaunch() throws {
        let proposal = PendingProposal(toolName: "delete_thing", kind: "delete_thing", summary: "Delete x",
                                       payload: Data(), origin: .external(clientID: "test/1"),
                                       why: "throwaway", session: UUID())
        let back = try JSONDecoder().decode(PendingProposal.self, from: JSONEncoder().encode(proposal))
        XCTAssertEqual(back, proposal)
        XCTAssertEqual(back.why, "throwaway")
    }

    func testAProposalStoredBeforeReasonsStillReads() throws {
        let now = PendingProposal(toolName: "t", kind: "k", summary: "s", payload: Data(),
                                  origin: .external(clientID: "test/1"), why: "w", session: UUID())
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(now)) as? [String: Any])
        stored["why"] = nil
        stored["session"] = nil
        let proposal = try JSONDecoder().decode(PendingProposal.self, from: JSONSerialization.data(withJSONObject: stored))
        XCTAssertNil(proposal.why)
        XCTAssertNil(proposal.session)
        XCTAssertEqual(proposal.id, now.id)
    }

    func testAnOverlongReasonIsClipped() {
        let clipped = Cause.clip(String(repeating: "a", count: 500))
        XCTAssertEqual(clipped?.count, Cause.maxWhy)
        XCTAssertTrue(clipped?.hasSuffix("…") == true)
        XCTAssertNil(Cause.clip("   "))
        XCTAssertNil(Cause.clip(nil))
    }

    // MARK: - It travels with the work

    func testTheCauseReachesChildTasks() async {
        let cause = Cause(why: "the rule", session: UUID())
        let inChild = await Cause.$current.withValue(cause) {
            await Task { Cause.current }.value
        }
        XCTAssertEqual(inChild, cause)
        XCTAssertEqual(Cause.current, Cause(), "none outside")
    }

    func testApplyingAProposalCarriesItsReasonCallAndWhoApplied() {
        let call = UUID()
        let proposal = PendingProposal(toolName: "t", kind: "k", summary: "s", payload: Data(),
                                       origin: .external(clientID: "test/1"), requestID: call,
                                       why: "throwaway", session: UUID())
        let cause = Cause.applying(proposal, by: .person)
        XCTAssertEqual(cause.why, "throwaway")
        XCTAssertEqual(cause.call, call)
        XCTAssertEqual(cause.proposal, proposal.id)
        XCTAssertEqual(cause.session, proposal.session)
        XCTAssertEqual(cause.appliedBy, .person)
    }

    func testARequestKeepsTheCauseOfItsWork() async throws {
        let ledger = RequestLedger()
        let cause = Cause(why: "throwaway", session: UUID(), call: UUID())
        _ = try await Cause.$current.withValue(cause) {
            try await ledger.send(URLRequest(url: URL(string: "https://ws-uv.canfar.net/skaha/v1/session")!)) { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        XCTAssertEqual(ledger.recent().last?.cause, cause)
    }
}
