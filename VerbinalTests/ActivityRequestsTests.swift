// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 23 L6: the activity bar and the service health read the request
/// ledger — what a task waits on, what its requests came to, and what the
/// app's own traffic showed of each service.
final class ActivityRequestsTests: XCTestCase {

    private let ledger = RequestLedger()
    private func context() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget())
    }

    private func send(_ url: String, task: Int, status: Int, wait: Duration = .zero) async throws {
        _ = try await Cause.$current.withValue(Cause(task: task)) {
            try await ledger.send(URLRequest(url: URL(string: url)!, timeoutInterval: 120)) { request in
                if wait > .zero { try await Task.sleep(for: wait) }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    @MainActor
    func testARunningTaskSaysWhatItWaitsOnAndAFinishedOneWhatItsRequestsCameTo() async throws {
        let registry = TaskRegistry()
        let running = registry.begin(.download, "Download observation x")
        let done = registry.begin(.launch, "Launch notebook y")
        try await send("https://ws-uv.canfar.net/skaha/v1/session", task: done.id, status: 200)
        try await send("https://ws-uv.canfar.net/skaha/v1/session", task: done.id, status: 503)
        done.succeed()
        let waiting = Task { try await self.send("https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/caom2ops/pkg", task: running.id,
                                                 status: 200, wait: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        let tasks = registry.tasks
        let ledger = self.ledger
        let tool = ListActivityTool(tasks: { tasks }, requests: { ledger.recent() + ledger.waiting() })
        let out = try await tool.handle(.init(), context: context())
        let download = try XCTUnwrap(out.tasks.first { $0.label == "Download observation x" })
        XCTAssertTrue(download.waitingOn?.hasPrefix("the CADC archive's files had waited 0 s of its 120 s") == true,
                      "\(String(describing: download.waitingOn))")
        let launch = try XCTUnwrap(out.tasks.first { $0.label == "Launch notebook y" })
        XCTAssertNil(launch.waitingOn)
        XCTAssertEqual(launch.requests?.count, 2)
        XCTAssertEqual(launch.requests?.failed, 1)
        waiting.cancel()
        running.succeed()
    }

    func testTheHealthAddsWhatTheAppsOwnTrafficShowed() async throws {
        try await send("https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync", task: 1, status: 200)
        try await send("https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync", task: 1, status: 503)
        let ledger = self.ledger
        let tool = GetServiceHealthTool(
            probe: { .init(services: [], probeStartedISO: "2026-09-30T14:00:00Z", healthyCount: 0) },
            seen: { ledger.stats() })
        let out = try await tool.handle(EmptyArgs(), context: context())
        let tap = try XCTUnwrap(out.seenByApp.first { $0.service == "cadc-tap" })
        XCTAssertEqual(tap.calls, 2)
        XCTAssertEqual(tap.failures, 1)
        XCTAssertEqual(tap.lastFailure?.outcome, "busy")
        XCTAssertEqual(tap.lastFailure?.code, "HTTP 503")
        XCTAssertNotNil(tap.lastAnswerAt)
        XCTAssertFalse(tap.failing)
    }
}
