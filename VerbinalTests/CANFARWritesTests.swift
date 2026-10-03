// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 30 W: a launch is on the activity bar whoever asks, and a change
/// tried again after it failed looks first for what the failed one may
/// have made — the QA pass's launches timed out, and Apply again could
/// have started a second session.
@MainActor
final class CANFARWritesTests: XCTestCase {

    private final class FakeSessions: SessionLaunching, SessionEnding, @unchecked Sendable {
        var launched: [String] = []
        var listed: [ListedSession]
        let answer: String?
        init(listed: [ListedSession] = [], answer: String? = "new1") { (self.listed, self.answer) = (listed, answer) }
        func launchSession(_ params: SessionLaunchParams) async throws -> String? { launched.append(params.name); return answer }
        func listing() async throws -> [ListedSession] { listed }
        func deleteSession(id: String) async throws {}
        func deleteDesktopApp(session: String, app: String) async throws {}
        func renewSession(id: String) async throws {}
    }

    private let params = SessionLaunchParams(type: "notebook", name: "qa-full-nb", image: "images.canfar.net/skaha/base-notebook:latest")

    func testALaunchIsATaskOnTheBar() async throws {
        let sessions = FakeSessions(), tasks = TaskRegistry()
        let launched = try await SessionLaunches(service: sessions, listing: sessions, tasks: tasks).launch(params)
        XCTAssertEqual(launched, .init(id: "new1", alreadyMade: false))
        XCTAssertEqual(tasks.tasks.map(\.label), ["Launch notebook qa-full-nb"])
        XCTAssertEqual(tasks.tasks.first?.message, "Session new1")
    }

    func testALaunchWithNoSessionIDFails() async {
        let sessions = FakeSessions(answer: nil), tasks = TaskRegistry()
        do {
            _ = try await SessionLaunches(service: sessions, tasks: tasks).launch(params)
            XCTFail("no id is no launch")
        } catch {
            XCTAssertEqual(error as? LaunchedWithoutID, LaunchedWithoutID())
            XCTAssertEqual(tasks.tasks.first?.progress, .failed)
        }
    }

    /// Tried again, the session the timed-out launch made is found, and
    /// nothing new is launched.
    func testARetryFindsWhatWasMadeAndLaunchesNothing() async throws {
        let sessions = FakeSessions(listed: [ListedSession(id: "abc123", type: "notebook", status: "Pending", name: "qa-full-nb")])
        let launches = SessionLaunches(service: sessions, listing: sessions, tasks: TaskRegistry())
        let again = try await launches.launch(params, checkFirst: true)
        XCTAssertEqual(again, .init(id: "abc123", alreadyMade: true))
        XCTAssertTrue(sessions.launched.isEmpty)
        let first = try await launches.launch(params)
        XCTAssertFalse(first.alreadyMade, "a first launch does not look: two of a name may be wanted")
        XCTAssertEqual(sessions.launched, ["qa-full-nb"])
    }

    /// The apply is told it is a retry once the same proposal has failed.
    func testAnApplyAfterAFailureIsARetry() async throws {
        final class Seen: @unchecked Sendable { var retries: [Bool] = [] }
        struct FailsOnce: ProposalApplier {
            let kind = "launch_session"
            let seen: Seen
            func apply(_ proposal: PendingProposal) async throws {
                seen.retries.append(ApplyAttempt.isRetry)
                if seen.retries.count == 1 { throw ProposalApplyError.backendError("timed out") }
            }
        }
        let seen = Seen()
        let store = InMemoryProposalStore()
        let agents = AgentsService(proposals: store)
        agents.register(appliers: [FailsOnce(seen: seen)])
        let proposal = await store.enqueue(PendingProposal(toolName: "launch_session", kind: "launch_session", summary: "Launch",
                                                           payload: Data("{}".utf8), origin: .external(clientID: "t")))
        try await Task.sleep(for: .milliseconds(50))
        _ = try? await agents.applyProposal(proposal.id, by: .autoApply)
        try await agents.applyProposal(proposal.id, by: .person)
        XCTAssertEqual(seen.retries, [false, true])
    }

    func testARetriedDeleteOfWhatIsGoneIsDone() async throws {
        let applier = DeleteSessionApplier(delete: { id, _ in throw NoSuchSession(id: id) },
                                           activity: AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let proposal = PendingProposal(toolName: "delete_session", kind: "delete_session", summary: "Delete",
                                       payload: try JSONEncoder().encode(DeleteSessionTool.Payload(id: "gone1", app: nil)),
                                       origin: .external(clientID: "t"))
        do {
            try await applier.apply(proposal)
            XCTFail("a first delete of an id the platform does not list is refused")
        } catch {}
        try await ApplyAttempt.$isRetry.withValue(true) { try await applier.apply(proposal) }
    }

    func testABatchRetryFindsWhatWasMade() async throws {
        struct Jobs: HeadlessLaunching {
            func launchHeadlessJob(_ params: HeadlessLaunchParams) async throws -> [String] { XCTFail("launched again"); return [] }
            func getHeadlessJobs() async throws -> [HeadlessJob] {
                [HeadlessJob(from: SkahaHeadlessResponse(id: "j1", userid: "u", image: "x", type: "headless", status: "Pending",
                                                         name: "qa-full-echo", startTime: nil, expiryTime: nil, connectURL: nil,
                                                         requestedRAM: nil, requestedCPUCores: nil, requestedGPUCores: nil,
                                                         ramInUse: nil, cpuCoresInUse: nil, isFixedResources: nil))]
            }
        }
        let launched = try await HeadlessLaunches(service: Jobs(), tasks: TaskRegistry())
            .launch(HeadlessLaunchParams(name: "qa-full-echo", image: "x", cmd: "echo", args: nil, env: [],
                                         cores: 1, ram: 1, gpus: nil, replicas: 1), checkFirst: true)
        XCTAssertEqual(launched, .init(ids: ["j1"], alreadyMade: true))
    }
}
