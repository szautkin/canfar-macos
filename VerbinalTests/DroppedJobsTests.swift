// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 30 J: a job CANFAR has dropped reads "gone", not "pending" — the QA
/// pass's job from five days before, read "pending", would have been polled
/// for ever.
final class DroppedJobsTests: XCTestCase {

    private let context = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                        budget: ProposalBudget(limit: 9))
    private let notFound = NetworkError.httpError(404, "session g8tf08li not found.")

    private func logs(fetch: @escaping @Sendable (String) async throws -> String, listed: Bool?) -> GetHeadlessJobLogsTool {
        GetHeadlessJobLogsTool(fetch: fetch, isListed: { _ in listed })
    }

    func testANotFoundJobIsPendingWhileListedAndGoneOnceNot() async throws {
        let notFound = notFound
        let queued = try await logs(fetch: { _ in throw notFound }, listed: true).handle(.init(id: "j1"), context: context)
        XCTAssertEqual(queued.state, "pending")
        let gone = try await logs(fetch: { _ in throw notFound }, listed: false).handle(.init(id: "j1"), context: context)
        XCTAssertEqual(gone.state, "gone")
        XCTAssertTrue(gone.upToDate, "nothing more will come")
        XCTAssertEqual(gone.note, HeadlessJobPresence.goneNote)
        let unknown = try await logs(fetch: { _ in throw notFound }, listed: nil).handle(.init(id: "j1"), context: context)
        XCTAssertEqual(unknown.state, "pending", "CANFAR cannot say: as before")
    }

    /// The pass's logs read "ready" and empty for the dropped job.
    func testEmptyLogsFromADroppedJobAreGone() async throws {
        let dropped = try await logs(fetch: { _ in "" }, listed: false).handle(.init(id: "j1"), context: context)
        XCTAssertEqual(dropped.state, "gone")
        let running = try await logs(fetch: { _ in "" }, listed: true).handle(.init(id: "j1"), context: context)
        XCTAssertEqual(running.state, "ready", "a running job with no output yet")
    }

    func testEventsOfADroppedJobAreGone() async throws {
        let notFound = notFound
        let events = GetHeadlessJobEventsTool(fetch: { _ in throw notFound }, isListed: { _ in false })
        let out = try await events.handle(.init(id: "j1"), context: context)
        XCTAssertEqual(out.state, "gone")
        XCTAssertEqual(out.note, HeadlessJobPresence.goneNote)
    }

    func testAProbeCANFARHasDroppedSaysItsLogsAreGone() async {
        let notFound = notFound
        let probe = GetProbeLogsTool(fetch: { _ in throw notFound })
        do {
            _ = try await probe.handle(.init(jobID: "cp3ahikm"), context: context)
            XCTFail("no logs to give")
        } catch let ToolFailureReason.backendError(message) {
            XCTAssertTrue(message.contains("CANFAR no longer lists probe job cp3ahikm"), message)
        } catch {
            XCTFail("\(error)")
        }
    }
}
