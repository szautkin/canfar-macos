// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
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

    func testASweepIsKeptAsItsLastFewInOneGo() {
        let history = JobHistoryStore(persistence: nil)
        let sweep = jobs(1_000, status: { _ in "Failed" }).map { HeadlessMonitorModel.record(of: $0) }
        history.record(sweep)
        XCTAssertEqual(history.jobs.count, JobHistoryStore.maxJobs)
        XCTAssertEqual(history.jobs.first?.id, "job999", "the last on top")
        XCTAssertEqual(Set(history.jobs.map(\.id)).count, JobHistoryStore.maxJobs, "each once")
    }
}
