// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// A session of any type is ended properly (the person, 2026-09-30:
/// "delete_session does not work properly for all types of sessions").
/// Skaha's own API: `DELETE /v1/session/{id}` leaves a desktop's apps
/// running and cannot stop one; `DELETE /v1/session/{id}/app/{appID}` does;
/// and a delete it could not make is answered 200, so the listing is asked.
final class SessionDeleteTests: XCTestCase {

    /// Skaha, as far as deleting goes: its listing, its two deletes, and
    /// every request made.
    private final class FakeSkaha: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [[String: String]]
        private(set) var requests: [String] = []
        /// A delete answered 200 and not made.
        var ignoresDeletes = false

        init(_ entries: [[String: String]]) { self.entries = entries }

        func handle(_ request: URLRequest) -> (HTTPURLResponse, Data) {
            lock.withLock {
                let path = request.url!.path
                let method = request.httpMethod ?? "GET"
                requests.append("\(method) \(path)")
                let parts = path.split(separator: "/").map(String.init)
                if method == "DELETE", !ignoresDeletes, let session = parts.firstIndex(of: "session").map({ parts[$0 + 1] }) {
                    if let app = parts.firstIndex(of: "app").map({ parts[$0 + 1] }) {
                        entries.removeAll { $0["id"] == session && $0["appid"] == app }
                    } else {
                        entries.removeAll { $0["id"] == session && $0["type"] != "desktop-app" }
                    }
                }
                let body = method == "GET" ? (try? JSONSerialization.data(withJSONObject: entries)) ?? Data() : Data()
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
        }

        var deletes: [String] { lock.withLock { requests.filter { $0.hasPrefix("DELETE") } } }
    }

    private let changes = ChangeLog()

    private func service(_ skaha: FakeSkaha) -> SessionService {
        MockURLProtocol.requestHandler = { skaha.handle($0) }
        return SessionService(network: NetworkClient(session: MockURLProtocol.mockSession()), changes: changes,
                              confirmation: (attempts: 2, interval: .milliseconds(1)))
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private let desktop: [[String: String]] = [
        ["id": "d1", "type": "desktop", "status": "Running", "name": "work"],
        ["id": "d1", "type": "desktop-app", "status": "Running", "name": "ds9", "appid": "a7"],
        ["id": "d1", "type": "desktop-app", "status": "Running", "name": "topcat", "appid": "b2"],
        ["id": "n1", "type": "notebook", "status": "Running", "name": "nb"],
    ]

    func testEndingADesktopStopsItsAppsFirst() async throws {
        let skaha = FakeSkaha(desktop)
        try await service(skaha).deleteSession(id: "d1")
        XCTAssertEqual(skaha.deletes, ["DELETE /skaha/v1/session/d1/app/a7", "DELETE /skaha/v1/session/d1/app/b2",
                                       "DELETE /skaha/v1/session/d1"])
        let left = try await service(skaha).listing().map(\.id)
        XCTAssertEqual(left, ["n1"], "the notebook untouched")
    }

    /// Before, its desktop's id ended the desktop and left the app running.
    func testOneDesktopAppIsStoppedWithoutItsDesktop() async throws {
        let skaha = FakeSkaha(desktop)
        try await service(skaha).deleteDesktopApp(session: "d1", app: "a7")
        XCTAssertEqual(skaha.deletes, ["DELETE /skaha/v1/session/d1/app/a7"])
        let left = try await service(skaha).listing().compactMap { $0.appid ?? $0.type }
        XCTAssertEqual(left, ["desktop", "b2", "notebook"])
    }

    func testAFinishedBatchJobIsDeleted() async throws {
        let skaha = FakeSkaha([["id": "keqh41rx", "type": "headless", "status": "Succeeded", "name": "qa-echo"]])
        try await service(skaha).deleteSession(id: "keqh41rx")
        XCTAssertEqual(skaha.deletes, ["DELETE /skaha/v1/session/keqh41rx"])
    }

    /// CANFAR answers 200 to a delete it did not make: the listing says so.
    func testADeleteThatDidNotTakeFailsAndSaysWhy() async throws {
        let skaha = FakeSkaha([["id": "c1", "type": "carta", "status": "Running", "name": "c"]])
        skaha.ignoresDeletes = true
        var heard: [Change] = []
        let lock = NSLock()
        changes.observe { change in lock.withLock { heard.append(change) } }
        do {
            try await service(skaha).deleteSession(id: "c1")
            XCTFail("it is still running")
        } catch let error as SessionStillRunning {
            XCTAssertEqual(error, SessionStillRunning(what: "session c1", status: "Running"))
        }
        let change = lock.withLock { heard.last }
        XCTAssertEqual(change?.outcome, .failed)
        XCTAssertTrue(change?.failure?.contains("still Running") == true, "\(String(describing: change?.failure))")
    }

    func testASessionAlreadyGoingCountsAsDeleted() async throws {
        let skaha = FakeSkaha([["id": "f1", "type": "firefly", "status": "Terminating", "name": "f"]])
        skaha.ignoresDeletes = true
        try await service(skaha).deleteSession(id: "f1")
    }

    // MARK: - The tools

    func testDeleteSessionNamesAnAppAndListSessionsListsThem() async throws {
        let plan = try await DeleteSessionTool().plan(.init(id: "d1", app: "a7"), context: AIToolContext(
            origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget()))
        XCTAssertEqual(plan.summary, "Stop desktop app a7 of session d1")
        XCTAssertEqual(try JSONDecoder().decode(DeleteSessionTool.Payload.self, from: plan.payload).app, "a7")
        let skaha = FakeSkaha(desktop)
        let sessions = service(skaha)
        let tool = ListSessionsTool(fetchAll: { [] }, fetchApps: { try await sessions.desktopApps() })
        let out = try await tool.handle(EmptyArgs(), context: AIToolContext(
            origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget()))
        XCTAssertEqual(out.desktopApps.map(\.app), ["a7", "b2"])
        XCTAssertEqual(out.desktopApps.first?.session, "d1")
    }

    /// A proposal stored before `app` existed still applies.
    func testAnOlderDeleteProposalStillReads() throws {
        let payload = try JSONDecoder().decode(DeleteSessionTool.Payload.self, from: Data(#"{"id":"n1"}"#.utf8))
        XCTAssertNil(payload.app)
    }
}
