// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
import VerbinalKit
@testable import Verbinal

/// Ten thousand batch jobs: an assistant gets them a page at a time, the
/// history takes each finished job once, and a sweep ending is one
/// notification and one write.
@MainActor
final class BatchJobsAtScaleTests: XCTestCase {

    private static let statuses = ["Running", "Pending", "Completed", "Failed"]

    /// Job `n` started `n` minutes after midnight; its status turns with `n`.
    private func jobs(_ count: Int, status: ((Int) -> String)? = nil) -> [HeadlessJob] {
        (0..<count).map { n in
            let started = Date(timeIntervalSince1970: 1_790_000_000 + Double(n) * 60)
            return HeadlessJob(from: SkahaHeadlessResponse(
                id: "job\(n)", userid: "u", image: "images.canfar.net/skaha/astroml:24.\(n % 3)", type: "headless",
                status: status?(n) ?? Self.statuses[n % 4], name: "sweep-\(n)",
                startTime: SharedFormatters.iso8601.string(from: started), expiryTime: nil, connectURL: nil,
                requestedRAM: "1G", requestedCPUCores: "1", requestedGPUCores: "0", ramInUse: nil, cpuCoresInUse: nil,
                isFixedResources: true))
        }
    }

    func testAPageIsBounded() {
        XCTAssertEqual(ToolPage(total: 10_000, cursor: nil, limit: nil), ToolPage(total: 10_000, cursor: "0", limit: 200))
        XCTAssertEqual(ToolPage(total: 10_000, cursor: nil, limit: nil).range, 0..<200)
        XCTAssertEqual(ToolPage(total: 10_000, cursor: "200", limit: 9_999).range, 200..<700, "at most 500")
        XCTAssertEqual(ToolPage(total: 450, cursor: "400", limit: nil).next, nil, "the last page")
        XCTAssertEqual(ToolPage(total: 450, cursor: "-5", limit: 0).range, 0..<1)
        XCTAssertEqual(ToolPage(total: 450, cursor: "900", limit: nil).range, 450..<450)
    }

    func testTheToolGivesTenThousandJobsAPageAtATime() {
        let all = jobs(10_000)
        let first = ListHeadlessJobsTool.output(all, .init())
        XCTAssertEqual(first.total, 10_000)
        XCTAssertEqual(first.counts, ["running": 2_500, "pending": 2_500, "completed": 2_500, "failed": 2_500])
        XCTAssertEqual(first.jobs.count, 200)
        XCTAssertEqual(first.jobs.first?.id, "job9999", "newest first")
        XCTAssertEqual(first.next, "200")

        let failed = ListHeadlessJobsTool.output(all, .init(phase: "failed", limit: 500))
        XCTAssertEqual(failed.matching, 2_500)
        XCTAssertTrue(failed.jobs.allSatisfy { $0.phase == "failed" })
        XCTAssertEqual(failed.counts["running"], 2_500, "counts cover every job")

        let one = ListHeadlessJobsTool.output(all, .init(contains: "SWEEP-4242"))
        XCTAssertEqual(one.jobs.map(\.id), ["job4242"])
        XCTAssertNil(one.next)
    }

    func testAFinishedJobIsOfferedToTheHistoryOnce() {
        let all = jobs(10_000, status: { _ in "Completed" })
        let first = HeadlessMonitorModel.firstSeenFinished(all, previous: nil)
        XCTAssertEqual(first.count, JobHistoryStore.maxJobs, "no more than it holds")
        XCTAssertEqual(first.first?.id, "job9999", "the latest started first")

        let seen = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.status) })
        XCTAssertTrue(HeadlessMonitorModel.firstSeenFinished(all, previous: seen).isEmpty,
                      "seen finished at the last poll: not again")
        let appeared = jobs(10_001, status: { _ in "Failed" })
        XCTAssertEqual(HeadlessMonitorModel.firstSeenFinished(appeared, previous: seen).map(\.id), ["job10000"],
                       "one that ended between two polls")
    }

    func testManyEndingAtOnceAreOneNotification() {
        XCTAssertNil(HeadlessMonitorModel.endedTogether(jobs(3, status: { _ in "Completed" })), "a few: each by name")
        let sweep = jobs(15, status: { $0 < 12 ? "Completed" : "Failed" })
        XCTAssertEqual(HeadlessMonitorModel.endedTogether(sweep), "12 done · 3 failed")
        XCTAssertEqual(HeadlessMonitorModel.endedTogether(jobs(1_000, status: { _ in "Completed" })),
                       HeadlessMonitorModel.StatusCount(status: .done, count: 1_000).text, "none failed: not said")
    }

    /// With no job listed, the card still opens the sheet: its History keeps
    /// what CANFAR no longer lists. (Handout 28 1.7 could not open it.)
    func testTheCardOpensTheSheetWithNoJobs() async throws {
        try await AXReadable.require()
        let model = HeadlessMonitorModel(
            headlessService: HeadlessService(network: NetworkClient(session: MockURLProtocol.mockSession())),
            history: JobHistoryStore(persistence: nil))
        XCTAssertTrue(model.jobs.isEmpty)
        let window = NSWindow(contentRect: NSRect(x: 220, y: 220, width: 480, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HeadlessJobsView(model: model).padding().uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let source = AXElementSource(screenName: { _, _, _ in "portal" })
        await source.ready()
        let open = try XCTUnwrap(source.snapshot().elements.first { $0.id == "portal.batchJobs" }, "a button with no jobs too")
        XCTAssertEqual(open.kind, .button)
        XCTAssertEqual(open.name, "Jobs & History…", "in sight, saying what it opens")
    }

    /// The list is filtered by every word of a job's name, image or id, and
    /// shows the newest first.
    func testTheSheetFiltersByNameImageOrIdNewestFirst() {
        let all = jobs(1_000, status: { _ in "Running" })
        XCTAssertEqual(HeadlessJobsDetailSheet.matching(all, filter: "").first?.id, "job999", "newest first")
        XCTAssertEqual(HeadlessJobsDetailSheet.matching(all, filter: "SWEEP-42 astroml").map(\.id).sorted(),
                       ["job42", "job420", "job421", "job422", "job423", "job424", "job425", "job426", "job427", "job428", "job429"])
        XCTAssertEqual(HeadlessJobsDetailSheet.matching(all, filter: "sweep-42 24.0").map(\.id),
                       ["job429", "job426", "job423", "job420", "job42"], "name and image words together, newest first")
    }

    /// Ten thousand jobs in a tab: the list holds a page of them, not all —
    /// opening and every poll drew all ten thousand rows (2 s, measured).
    func testTheSheetHoldsAPageNotTenThousand() async throws {
        let model = HeadlessMonitorModel(
            headlessService: HeadlessService(network: NetworkClient(session: MockURLProtocol.mockSession())),
            history: JobHistoryStore(persistence: nil))
        model.jobs = jobs(10_000, status: { _ in "Running" })
        model.runningCount = 10_000
        let window = NSWindow(contentRect: NSRect(x: 200, y: 150, width: 700, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HeadlessJobsDetailSheet(model: model).frame(width: 700, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        func table(_ view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap(table).first
        }
        let rows = try XCTUnwrap(window.contentView.flatMap(table)).numberOfRows
        XCTAssertEqual(rows, HeadlessJobsDetailSheet.pageSize)
    }

    /// A poll that finds the jobs as they were sets nothing: nothing showing
    /// them is drawn again.
    func testAPollThatFindsNothingNewSetsNothing() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = #"""
            [{"id": "a", "userid": "u", "image": "images.canfar.net/p/x:1", "type": "headless", "status": "Running", "name": "a"},
             {"id": "b", "userid": "u", "image": "images.canfar.net/p/x:1", "type": "headless", "status": "Completed", "name": "b"}]
            """#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let model = HeadlessMonitorModel(
            headlessService: HeadlessService(network: NetworkClient(session: MockURLProtocol.mockSession())))
        await model.loadJobs()
        XCTAssertEqual(model.jobs.count, 2)
        var touched = false
        withObservationTracking {
            _ = model.jobs
            _ = model.runningCount
            _ = model.completedCount
        } onChange: { touched = true }
        await model.loadJobs()
        XCTAssertFalse(touched, "the same jobs, the same counts: nothing set")
    }

    /// The sheet opens on the first tab with anything in it: History when
    /// CANFAR lists no job now.
    func testTheSheetOpensWhereThereIsSomething() {
        XCTAssertEqual(HeadlessJobsDetailSheet.firstTab([("running", 2), ("pending", 1), ("history", 5)]), "running")
        XCTAssertEqual(HeadlessJobsDetailSheet.firstTab([("running", 0), ("pending", 0), ("completed", 3)]), "completed")
        XCTAssertEqual(HeadlessJobsDetailSheet.firstTab([("running", 0), ("failed", 0), ("history", 4)]), "history")
        XCTAssertEqual(HeadlessJobsDetailSheet.firstTab([("running", 0), ("history", 0)]), "running")
    }

    func testASweepIsKeptAsItsLastFewInOneGo() {
        let history = JobHistoryStore(persistence: nil)
        let sweep = jobs(1_000, status: { _ in "Failed" }).map { HeadlessMonitorModel.record(of: $0) }
        history.record(sweep)
        XCTAssertEqual(history.jobs.count, JobHistoryStore.maxJobs)
        XCTAssertEqual(history.jobs.first?.id, "job999", "the last on top")
        XCTAssertEqual(Set(history.jobs.map(\.id)).count, JobHistoryStore.maxJobs, "each once")
    }
}
