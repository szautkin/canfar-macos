// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 23 L2: one log per assistant session, stored, telling everything
/// that happens in the app while it is open — who, why, how it ended.
final class SessionLogTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessionlog-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func header(_ session: UUID = UUID(), client: String = "claude-code/2.1", opened: Date = Date()) -> SessionLogHeader {
        SessionLogHeader(session: session, client: client, opened: opened, app: "1.4.0 (17)", buildCommit: "abc1234",
                         macOS: "26.0", endpoints: ["registry": "https://cadc-west-01.canfar.net/reg"], overridden: [],
                         autoApply: true, signedIn: true)
    }

    /// A hub with its own sources, so a test hears only itself.
    private struct Rig {
        let hub: AppEventHub
        let requests = RequestLedger()
        let changes = ChangeLog()
        let decisions = DecisionLog()
        let proposals = Observers<AgentEventEntry>()
        let tasks = Observers<TrackedTask>()
        let store: SessionLogStore

        init(directory: URL, header: @escaping AppEventHub.HeaderSource) {
            store = SessionLogStore(directory: directory)
            hub = AppEventHub(store: store, sources: .init(requests: requests, changes: changes, decisions: decisions,
                                                           proposals: proposals, tasks: tasks),
                              header: header)
        }
    }

    private func rig() -> Rig {
        Rig(directory: directory) { [header = self.header] session, client in header(session, client, Date()) }
    }

    private func entries(_ rig: Rig, _ session: UUID) async -> [SessionLogEntry] {
        guard let journal = await rig.hub.journal(for: session) else { return [] }
        return await journal.entries
    }

    private func answer(_ status: Int) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    // MARK: - The journal

    func testEntriesAreKeptInOrderWithTokensAndWritten() async throws {
        let store = SessionLogStore(directory: directory)
        let journal = SessionJournal(header: header(), store: store)
        await journal.record(SessionLogLine.signedIn("alice"))
        await journal.record(SessionLogLine.signedOut())
        let (entries, expired) = await journal.entries(since: 1)
        XCTAssertEqual(entries.map(\.token), [2])
        XCTAssertFalse(expired)
        let stored = try XCTUnwrap(store.read(try XCTUnwrap(store.list().first).url))
        XCTAssertEqual(stored.entries.map(\.line), ["The person signed in as alice.",
                                                    "The person signed out: everything that needs their CADC account waits for a sign-in."])
        XCTAssertEqual(stored.header.client, "claude-code/2.1")
    }

    /// Past its limit a log drops the oldest of what matters least —
    /// changes last, the session's terms never — and says how many went.
    func testALogPastItsLimitDropsTheLeastFirstAndSaysSo() async throws {
        let store = SessionLogStore(directory: directory)
        let journal = SessionJournal(header: header(), store: store, maxBytes: 3_000)
        let change = Change(id: UUID(), kind: "delete_session", verb: "deleted", what: "session keepme", startedBy: .person,
                            cause: Cause(), started: Date(), finished: Date(), outcome: .done, failure: nil, task: nil)
        let asked = SessionApprovals.Request(id: UUID(), client: "claude-code/2.1", mcpVersion: nil, agent: "Claude",
                                             model: nil, purpose: nil, askedAt: Date())
        await journal.record(SessionLogLine.started(.init(request: asked, instructions: "Stay in Verbinal.", allowedAt: Date())))
        await journal.record(SessionLogLine.action(change, seen: SessionViewpoint(session: UUID())))
        for _ in 0..<30 { await journal.record(SessionLogLine.signedIn("someone-with-a-long-name")) }
        let (entries, _) = await journal.entries(since: 0)
        XCTAssertTrue(entries.contains { $0.kind == .started }, "the session's terms are kept")
        XCTAssertTrue(entries.contains { $0.kind == .action }, "the change is kept")
        XCTAssertTrue(entries.contains { $0.outcome == "trimmed" }, "it says what went")
        let (_, expired) = await journal.entries(since: 2)
        XCTAssertTrue(expired, "a reader at token 2 missed what was dropped")
        XCTAssertLessThanOrEqual(try XCTUnwrap(store.list().first).bytes, 3_000)
    }

    // MARK: - The store

    func testAQuitLeavesTheSessionClosedAsVerbinalQuit() async throws {
        let store = SessionLogStore(directory: directory)
        do {
            let journal = SessionJournal(header: header(), store: store)
            await journal.record(SessionLogLine.signedIn("alice"))
            // Open, its file is held: not taken for abandoned.
            store.closeAbandoned(open: [])
            XCTAssertNil(store.list().first?.ending)
        }
        // No close, and its journal gone: the app quit.
        try await Task.sleep(for: .milliseconds(50))
        store.closeAbandoned(open: [])
        let log = try XCTUnwrap(store.list().first)
        XCTAssertEqual(log.ending, "verbinalQuit")
        XCTAssertEqual(store.read(log.url)?.entries.last?.line, "Verbinal quit while the session was open.")
    }

    func testRetentionKeepsTenDaysAndTenMegabytesNeverAnOpenLog() {
        let now = Date()
        func log(_ days: Double, _ megabytes: Double, open: UUID = UUID()) -> StoredSessionLog {
            StoredSessionLog(url: URL(fileURLWithPath: "/tmp/\(open).jsonl"), header: header(open, opened: now.addingTimeInterval(-days * 86_400)),
                             bytes: Int(megabytes * 1_048_576), lastAt: now.addingTimeInterval(-days * 86_400),
                             entries: 1, actions: 0, failures: 0, ending: "disconnected")
        }
        let old = log(11, 0.1)
        let open = log(12, 0.1)
        let big = [log(1, 4), log(2, 4), log(3, 4)]
        let removed = SessionLogRetention.toRemove([old, open] + big, open: [open.header.session], now: now)
        XCTAssertTrue(removed.contains(old), "older than 10 days")
        XCTAssertFalse(removed.contains(open), "never an open one")
        XCTAssertTrue(removed.contains(big[2]), "the oldest goes to bring 12 MB within 10")
        XCTAssertFalse(removed.contains(big[0]))
    }

    // MARK: - The hub

    func testTwoConnectionsFromOneClientAreTwoSessions() async {
        let rig = rig()
        let first = UUID(), second = UUID()
        await rig.hub.opened(first, client: "claude-code/2.1")
        await rig.hub.opened(second, client: "claude-code/2.1")
        let open = await rig.hub.openSessions
        XCTAssertEqual(open, [first, second])
        let told = await entries(rig, first).map(\.line)
        XCTAssertEqual(told.last, "Another assistant connected: claude-code/2.1.")
    }

    /// An assistant's delete, applied by the person: who, why, how.
    func testAnAppliedChangeSaysWhoProposedItWhoAppliedItAndWhy() async throws {
        let rig = rig()
        let session = UUID()
        await rig.hub.opened(session, client: "claude-code/2.1")
        let proposal = PendingProposal(toolName: "delete_session", kind: "delete_session", summary: "Delete session q9p87ajc",
                                       payload: Data(), origin: .external(clientID: "claude-code/2.1"),
                                       why: "throwaway from the QA pass", session: session)
        try await Initiator.$current.withValue(.assistant) {
            try await rig.changes.applying(proposal, by: .person) { }
        }
        await rig.hub.settle()
        let told = await entries(rig, session)
        let action = try XCTUnwrap(told.first { $0.kind == .action })
        XCTAssertTrue(action.line.hasPrefix("Deleted session q9p87ajc — by the assistant, applied by the person, because: throwaway from the QA pass. Done in"), action.line)
        XCTAssertEqual(action.who, .assistant)
        XCTAssertEqual(action.why, "throwaway from the QA pass")
        XCTAssertEqual(action.ids.proposal, proposal.id)
    }

    func testThePersonsChangeIsTheirs() async throws {
        let rig = rig()
        let session = UUID()
        await rig.hub.opened(session, client: "claude-code/2.1")
        rig.changes.done("vospace_mkdir", "folder data/run2 in storage")
        await rig.hub.settle()
        let told = await entries(rig, session)
        let action = try XCTUnwrap(told.first { $0.kind == .action })
        XCTAssertTrue(action.line.hasPrefix("Made folder data/run2 in storage — by the person. Done in"), action.line)
        XCTAssertEqual(action.who, .person)
    }

    /// A call tells its own requests; a failure outside any call is its own entry.
    func testACallTellsItsRequestsAndAFailureOutsideIsItsOwn() async throws {
        let rig = rig()
        let session = UUID(), call = UUID()
        await rig.hub.opened(session, client: "claude-code/2.1")
        await rig.hub.callBegan(session, call: call, tool: "search_observations")
        let trace = RequestTrace(parent: nil)
        try await Cause.$current.withValue(Cause(session: session, call: call)) {
            _ = try await trace.run {
                try await rig.requests.send(URLRequest(url: URL(string: "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync")!),
                                            answer(503))
            }
        }
        await rig.hub.settle()
        let token = await rig.hub.callEnded(session, call: call, tool: "search_observations",
                                            traced: .init(result: .failed(.backendError("HTTP 503")), seconds: 1.2, trace: trace))
        _ = try await rig.requests.send(URLRequest(url: URL(string: "https://ws-uv.canfar.net/skaha/v1/session")!), answer(500))
        await rig.hub.settle()
        let entries = await entries(rig, session)
        let callEntry = try XCTUnwrap(entries.first { $0.kind == .call })
        XCTAssertEqual(callEntry.requests?.map(\.service), ["cadc-tap"])
        XCTAssertTrue(callEntry.line.contains("the CADC archive search is busy"), callEntry.line)
        XCTAssertEqual(callEntry.retry, "later")
        XCTAssertEqual(token, callEntry.token, "the reply's note points at the call's entry")
        let requests = entries.filter { $0.kind == .request }
        XCTAssertEqual(requests.count, 1, "the call's own failure is not told twice")
        XCTAssertTrue(requests.first?.line.hasPrefix("CANFAR sessions failed on its side: a request by the person") == true)
    }

    func testClosingTellsTheOthersAndEndsTheLog() async throws {
        let rig = rig()
        let first = UUID(), second = UUID()
        await rig.hub.opened(first, client: "claude-code/2.1")
        await rig.hub.opened(second, client: "cursor/1.0")
        await rig.hub.closed(second)
        let told = await entries(rig, first).last?.line
        XCTAssertEqual(told, "Another assistant left: cursor/1.0.")
        let closed = try XCTUnwrap(rig.store.list().first { $0.header.session == second })
        XCTAssertEqual(closed.ending, "disconnected")
    }

    /// Nothing of a login — its form, its path — reaches a session's file.
    func testASignInLeavesNothingOfItsFormInTheFile() async throws {
        let rig = rig()
        let session = UUID()
        await rig.hub.opened(session, client: "claude-code/2.1")
        var login = URLRequest(url: URL(string: "https://ws-cadc.canfar.net/ac/login")!)
        login.httpMethod = "POST"
        login.httpBody = Data("username=alice&password=hunter2-secret".utf8)
        _ = try await rig.requests.send(login, answer(401))
        await rig.hub.settle()
        let text = try String(contentsOf: try XCTUnwrap(rig.store.list().first).url, encoding: .utf8)
        XCTAssertTrue(text.contains("CADC sign-in needs the person to sign in"), text)
        for leak in ["hunter2", "password=", "/ac/login"] { XCTAssertFalse(text.contains(leak), leak) }
    }
}
