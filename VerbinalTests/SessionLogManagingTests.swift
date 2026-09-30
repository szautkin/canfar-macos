// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 23 L4: session logs exported, deleted — never an open one — and
/// kept by the rule, each recorded as a change.
@MainActor
final class SessionLogManagingTests: XCTestCase {

    private var directory: URL!
    private var out: URL!
    private let changes = ChangeLog()
    private var heard: [Change] = []
    private var store: SessionLogStore!
    private var hub: AppEventHub!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessionmanage-\(UUID().uuidString)")
        out = FileManager.default.temporaryDirectory.appendingPathComponent("sessionexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let box = Box()
        changes.observe { change in box.add(change) }
        self.box = box
        store = SessionLogStore(directory: directory, changes: changes)
        hub = AppEventHub(store: store, sources: .init(requests: RequestLedger(), changes: ChangeLog(), decisions: DecisionLog())) { session, client in
            SessionLogHeader(session: session, client: client, opened: Date(), app: "1.4.0 (17)", buildCommit: "abc1234",
                             macOS: "26.0", endpoints: ["registry": "https://cadc-west-01.canfar.net/reg"], overridden: [],
                             autoApply: true, signedIn: true)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: out)
        super.tearDown()
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Change] = []
        func add(_ change: Change) { lock.withLock { list.append(change) } }
        var changes: [Change] { lock.withLock { list } }
    }
    private var box: Box!

    private var query: SessionLogQuery { SessionLogQuery(store: store, hub: hub) }

    private func context(_ session: UUID? = nil) -> AIToolContext {
        AIToolContext(origin: .external(clientID: "claude-code/2.1"), proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(), session: session)
    }

    /// Two closed sessions and an open one.
    private func sessions() async -> (closed: [UUID], open: UUID) {
        let first = UUID(), second = UUID(), open = UUID()
        for id in [first, second, open] { await hub.opened(id, client: "claude-code/2.1") }
        await hub.closed(first)
        await hub.closed(second)
        return ([first, second], open)
    }

    // MARK: - Export

    func testTheTextExportHeadsEachSessionAndMatchesTheViewsLines() async throws {
        let (closed, _) = await sessions()
        var logs: [SessionLogExport.Log] = []
        for id in closed { if let log = await query.log(of: id) { logs.append((log.header, log.entries)) } }
        let url = out.appendingPathComponent("logs.txt")
        try SessionLogExport.write(logs, as: .text, to: url, changes: changes)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "Verbinal session log — claude-code/2.1").count - 1, 2, "each session headed")
        XCTAssertTrue(text.contains("Verbinal 1.4.0 (17), abc1234, macOS 26.0"))
        XCTAssertTrue(text.contains(SessionLogLine.timed(logs[0].entries[0])), "the view's line")
        XCTAssertEqual(box.changes.last?.sentence, "Exported 2 session logs to logs.txt")
    }

    func testTheJSONLinesExportIsTheStoredForm() async throws {
        let (closed, _) = await sessions()
        let found = await query.log(of: closed[0])
        let log = try XCTUnwrap(found)
        let url = out.appendingPathComponent("log.jsonl")
        try SessionLogExport.write([(log.header, log.entries)], as: .jsonl, to: url, changes: changes)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1 + log.entries.count)
        XCTAssertTrue(lines[0].hasPrefix(#"{"header":"#))
    }

    func testTheAssistantsExportLandsInItsFolderAndNamesTheFile() async throws {
        let (closed, _) = await sessions()
        let tool = ExportSessionLogTool(query: query)
        let plan = try await tool.plan(.init(sessions: ["all"], format: "text"), context: context())
        XCTAssertEqual(plan.summary, "Export 3 session logs as text to Downloads")
        XCTAssertEqual(ExportSessionLogTool.verbClass, .semanticWrite)
        let proposal = PendingProposal(toolName: "export_session_log", kind: plan.kind, summary: plan.summary,
                                       payload: plan.payload, origin: .external(clientID: "claude-code/2.1"))
        var applier = ExportSessionLogApplier(query: query, activity: AgentActivityStore())
        applier.folder = { [out] in out! }
        let data = try await applier.applyReturningResult(proposal)
        let file = try XCTUnwrap(try JSONDecoder().decode(AutoAppliedAck.Extra.self, from: data).file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
        XCTAssertTrue(file.hasSuffix(".txt"))
        _ = closed
    }

    // MARK: - Delete

    func testAnOpenSessionsLogIsNeverDeleted() async throws {
        let (closed, open) = await sessions()
        let deleted = store.delete(Set(closed + [open]), open: await hub.openSessions)
        XCTAssertEqual(Set(deleted), Set(closed))
        XCTAssertEqual(store.list().map(\.header.session), [open])
        XCTAssertTrue(box.changes.last?.sentence.hasPrefix("Deleted 2 session logs") == true)
    }

    func testTheAssistantsDeleteWaitsForThePersonAndRefusesOpenLogs() async throws {
        let (_, open) = await sessions()
        XCTAssertEqual(DeleteSessionLogsTool.verbClass, .destructive)
        let tool = DeleteSessionLogsTool(query: query)
        let plan = try await tool.plan(.init(allClosed: true), context: context(open))
        XCTAssertTrue(plan.summary.hasPrefix("Delete 2 session logs"), plan.summary)
        do {
            _ = try await tool.plan(.init(sessions: [open.uuidString]), context: context(open))
            XCTFail("an open log is not deleted")
        } catch let ToolFailureReason.invalidArgument(message) {
            XCTAssertTrue(message.contains("never deleted"))
        }
    }

    // MARK: - Retention

    func testRetentionIsVerbinalsChangeWithTheRuleAsItsWhy() async throws {
        let (closed, _) = await sessions()
        let removed = store.applyRetention(open: await hub.openSessions, now: Date().addingTimeInterval(11 * 86_400))
        XCTAssertEqual(Set(removed), Set(closed))
        let change = try XCTUnwrap(box.changes.last)
        XCTAssertEqual(change.startedBy, .app)
        XCTAssertEqual(change.cause.why, SessionLogRetention.rule)
    }

    // MARK: - The person's view

    func testTheViewListsWhatTheToolLists() async throws {
        let (_, open) = await sessions()
        let model = SessionLogsModel(query: query)
        await model.reload()
        let listed = try await ListSessionLogsTool(query: query).handle(EmptyArgs(), context: context(open))
        XCTAssertEqual(model.logs.map(\.header.session.uuidString), listed.sessions.map(\.session))
        XCTAssertEqual(model.open, [open])
        XCTAssertEqual(model.closedCount, 2)
        model.selection = [open]
        XCTAssertFalse(model.canDeleteSelection, "an open log cannot be deleted")
    }
}
