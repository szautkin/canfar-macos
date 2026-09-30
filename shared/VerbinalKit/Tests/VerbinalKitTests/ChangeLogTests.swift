// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import XCTest
@testable import VerbinalKit

/// Plan 23 C: every change recorded once, by the one who makes it, with
/// who, why and how it ended.
final class ChangeLogTests: XCTestCase {

    /// A log and what it heard.
    final class Heard: @unchecked Sendable {
        let log = ChangeLog()
        private let lock = NSLock()
        private var list: [Change] = []
        init() { log.observe { [weak self] change in self?.lock.withLock { self?.list.append(change) } } }
        var changes: [Change] { lock.withLock { list } }
    }

    private struct Refused: LocalizedError {
        var errorDescription: String? { "the platform refused" }
    }

    private func proposal(_ kind: String, _ summary: String, why: String? = nil) -> PendingProposal {
        PendingProposal(toolName: kind, kind: kind, summary: summary, payload: Data(),
                        origin: .external(clientID: "test/1"), requestID: UUID(), why: why, session: UUID())
    }

    func testAChangeIsRecordedWithWhoWhyAndHowItEnded() async throws {
        let heard = Heard()
        let cause = Cause(why: "the rule")
        try await Initiator.$current.withValue(.app) {
            try await Cause.$current.withValue(cause) {
                try await heard.log.run("delete_session", "session q9p87ajc") { }
            }
        }
        let change = try XCTUnwrap(heard.changes.first)
        XCTAssertEqual(change.kind, "delete_session")
        XCTAssertEqual(change.verb, "deleted")
        XCTAssertEqual(change.sentence, "Deleted session q9p87ajc")
        XCTAssertEqual(change.outcome, .done)
        XCTAssertEqual(change.startedBy, .app)
        XCTAssertEqual(change.cause, cause)
        XCTAssertNil(change.failure)
    }

    func testAFailedChangeSaysWhyAndStillThrows() async {
        let heard = Heard()
        do {
            try await heard.log.run("launch_session", "notebook session x") { throw Refused() }
            XCTFail("the error goes on")
        } catch {}
        XCTAssertEqual(heard.changes.first?.outcome, .failed)
        XCTAssertEqual(heard.changes.first?.failure, "the platform refused")
    }

    func testAnApplyFailureSaysItsOwnMessage() async {
        let heard = Heard()
        _ = try? await heard.log.run("renew_session", "session x") { throw ProposalApplyError.backendError("no such session x") }
        XCTAssertEqual(heard.changes.first?.failure, "no such session x")
    }

    func testAStoppedChangeIsCancelledNotFailed() async {
        let heard = Heard()
        _ = try? await heard.log.run("download_observation", "observation x") { throw CancellationError() }
        XCTAssertEqual(heard.changes.first?.outcome, .cancelled)
        XCTAssertNil(heard.changes.first?.failure)
    }

    /// An assistant's change is recorded where it is applied — its summary,
    /// its why, who applied it — and its owner does not record it again.
    func testAnAppliedProposalIsRecordedOnceWithItsWhyAndWhoApplied() async throws {
        let heard = Heard()
        let delete = proposal("delete_session", "Delete session q9p87ajc", why: "throwaway from the QA pass")
        try await heard.log.applying(delete, by: .person) {
            try await heard.log.run("delete_session", "session q9p87ajc") { }
            heard.log.done("delete_session", "session q9p87ajc")
        }
        XCTAssertEqual(heard.changes.count, 1, "once")
        let change = try XCTUnwrap(heard.changes.first)
        XCTAssertEqual(change.sentence, "Deleted session q9p87ajc")
        XCTAssertEqual(change.cause.why, "throwaway from the QA pass")
        XCTAssertEqual(change.cause.proposal, delete.id)
        XCTAssertEqual(change.cause.appliedBy, .person)
        XCTAssertEqual(change.cause.call, delete.requestID)
    }

    func testAChangeKnowsTheTaskThatTrackedIt() async throws {
        let heard = Heard()
        try await Cause.$current.withValue(Cause(task: 7)) {
            try await heard.log.run("download_observation", "observation x") { }
        }
        heard.log.done("launch_headless_job", "batch job y", task: 9)
        XCTAssertEqual(heard.changes.map(\.task), [7, 9])
    }

    // MARK: - Verbs

    func testTheVerbComesFromTheKindsOwnWords() {
        XCTAssertEqual(ChangeVerb.of(kind: "delete_session"), "deleted")
        XCTAssertEqual(ChangeVerb.of(kind: "bulk_update_observation_notes"), "updated")
        XCTAssertEqual(ChangeVerb.of(kind: "vospace_mkdir"), "made")
        XCTAssertEqual(ChangeVerb.of(kind: "discover_image_packages"), "inspected")
        XCTAssertEqual(ChangeVerb.of(kind: "run_code"), "ran")
        XCTAssertNil(ChangeVerb.of(kind: "frobnicate_widget"))
    }

    func testASummaryBecomesTheObjectOfItsVerb() {
        XCTAssertEqual(ChangeVerb.object(of: "Delete session q9p87ajc", kind: "delete_session"), "session q9p87ajc")
        XCTAssertEqual(ChangeVerb.object(of: "Download 5 observations from JWST", kind: "download_observations_bulk"),
                       "5 observations from JWST")
        XCTAssertEqual(ChangeVerb.object(of: "M31 to Research", kind: "save_observation_to_research"), "M31 to Research",
                       "kept when it does not start with its verb")
    }
}
