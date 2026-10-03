// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import XCTest
@testable import VerbinalKit

/// Plan 23 A: each decision the app takes is recorded by the policy that
/// takes it, with its rule in words.
final class DecisionLogTests: XCTestCase {

    final class Heard: @unchecked Sendable {
        let log = DecisionLog()
        private let lock = NSLock()
        private var list: [Decision] = []
        init() { log.observers.observe { [weak self] decision in self?.lock.withLock { self?.list.append(decision) } } }
        var decisions: [Decision] { lock.withLock { list } }
    }

    private struct Write: JSONWriteTool {
        static var verbClass: VerbClass { .semanticWrite }
        struct Args: Decodable, Sendable {}
        let definition = AIToolDefinition.withStaticSchema(
            name: "save_thing", description: "Saves a thing.", schema: #"{"type":"object","properties":{}}"#)
        func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
            ProposalPlan(kind: "save_thing", summary: "Save the thing", payload: Data())
        }
    }

    private struct Delete: JSONWriteTool {
        static var verbClass: VerbClass { .destructive }
        struct Args: Decodable, Sendable {}
        let definition = AIToolDefinition.withStaticSchema(
            name: "delete_thing", description: "Deletes a thing.", schema: #"{"type":"object","properties":{}}"#)
        func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
            ProposalPlan(kind: "delete_thing", summary: "Delete the thing", payload: Data())
        }
    }

    private func context() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test/1"), proposals: InMemoryProposalStore(), budget: ProposalBudget(),
                      session: UUID())
    }

    // MARK: - Auto-apply

    func testEachRuleIsSaidInWords() {
        XCTAssertTrue(AutoApplyPolicy.rule(for: .semanticWrite, appliedAtOnce: true).contains("Auto-apply is on"))
        XCTAssertTrue(AutoApplyPolicy.rule(for: .semanticWrite, appliedAtOnce: false).contains("Auto-apply is off"))
        XCTAssertTrue(AutoApplyPolicy.rule(for: .destructive, appliedAtOnce: false).contains("a delete always waits"))
        XCTAssertTrue(AutoApplyPolicy.rule(for: .standingInstruction, appliedAtOnce: false).contains("always waits"))
    }

    func testADeleteHeldForThePersonSaysWhy() async throws {
        let heard = Heard()
        let router = AIToolRouter(tools: [Delete()], auditSink: CapturingAuditSink(), decisions: heard.log)
        let result = await router.dispatch(name: "delete_thing", rawArguments: Data("{}".utf8), context: context())
        guard case .proposed(let proposal) = result else { return XCTFail("\(result)") }
        let decision = try XCTUnwrap(heard.decisions.first)
        XCTAssertEqual(decision.rule, .heldForPerson)
        XCTAssertEqual(decision.sentence, "\"Delete the thing\" waits in Pending: a delete always waits for the person, whatever Auto-apply says")
        XCTAssertEqual(decision.cause.proposal, proposal.id)
    }

    func testAWriteAppliedAtOnceSaysWhy() async throws {
        let heard = Heard()
        let hook = AutoApplyHook(shouldAutoApply: { verbClass, _ in AutoApplyPolicy.appliesAtOnce(verbClass, autoApplyOn: true) },
                                 apply: { _ in nil })
        let router = AIToolRouter(tools: [Write()], auditSink: CapturingAuditSink(), autoApplyHook: hook, decisions: heard.log)
        _ = await router.dispatch(name: "save_thing", rawArguments: Data("{}".utf8), context: context())
        XCTAssertEqual(heard.decisions.map(\.rule), [.appliedAtOnce])
        XCTAssertTrue(heard.decisions.first?.sentence.contains("Auto-apply is on") == true)
    }

    // MARK: - Retries

    func testARetryAndAGiveUpAreEachSaid() async {
        let heard = Heard()
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1), maxDelay: .milliseconds(2))
        _ = try? await retrying(policy, decisions: heard.log) { () async throws -> Int in
            throw NetworkError.httpError(503, "")
        }
        XCTAssertEqual(heard.decisions.map(\.rule), [.retried, .notRetried])
        XCTAssertTrue(heard.decisions.first?.sentence.contains("asked again in") == true, "\(heard.decisions)")
        XCTAssertTrue(heard.decisions.last?.sentence.contains("2 attempts made") == true, "\(heard.decisions)")
    }

    func testATimeoutIsNotAskedAgainAndSaysWhy() async {
        let heard = Heard()
        _ = try? await retrying(.longRequests, decisions: heard.log) { () async throws -> Int in
            throw URLError(.timedOut)
        }
        XCTAssertEqual(heard.decisions.map(\.rule), [.notRetried])
        XCTAssertTrue(heard.decisions.first?.sentence.contains("would wait its whole timeout again") == true)
    }

    // MARK: - Deadlines

    /// A deadline says what was still in flight, in the error and the log.
    func testADeadlineNamesTheRequestStillWaiting() async throws {
        let heard = Heard()
        let ledger = RequestLedger()
        let trace = RequestTrace()
        do {
            _ = try await trace.run {
                try await withToolTimeout(seconds: 0.2, label: "search_observations", decisions: heard.log) {
                    try await ledger.send(URLRequest(url: URL(string: "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync")!,
                                                     timeoutInterval: 120)) { request -> (Data, URLResponse) in
                        try await Task.sleep(for: .seconds(5))
                        throw URLError(.timedOut)
                    }
                }
            }
            XCTFail("the deadline was reached")
        } catch let ToolFailureReason.backendError(message) {
            XCTAssertTrue(message.contains("search_observations exceeded 0s deadline"), message)
            XCTAssertTrue(message.contains("the CADC archive search had waited 0 s of its 120 s and had not answered"), message)
        }
        XCTAssertEqual(heard.decisions.map(\.rule), [.stoppedWaiting])
        XCTAssertTrue(heard.decisions.first?.sentence.hasPrefix("search_observations stopped waiting after 0 s; the CADC archive search") == true)
    }

    func testADeadlineWithNothingWaitingSaysSo() async {
        let heard = Heard()
        var said = ""
        do {
            try await RequestTrace().run {
                try await withApplierTimeout(seconds: 0.1, label: "export_thing", decisions: heard.log) {
                    try await Task.sleep(for: .seconds(5))
                }
            }
        } catch let error as ProposalApplyError {
            said = error.message
        } catch {}
        XCTAssertTrue(heard.decisions.first?.sentence.contains("no request to CADC or CANFAR was waiting") == true)
        // Plan 30 W2: it may have gone through — never "check the activity
        // feed", which may hold no record of it.
        XCTAssertTrue(said.contains("it may have gone through all the same: check before trying again"), said)
        XCTAssertFalse(said.contains("activity feed"), said)
    }
}
