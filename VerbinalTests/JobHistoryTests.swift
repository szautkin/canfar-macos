// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Finished batch jobs, kept after the platform forgets them: newest first,
/// once each, and never losing the reason one sighting had.
@MainActor
final class JobHistoryTests: XCTestCase {

    private func job(_ id: String, _ outcome: JobRecord.Outcome = .failed, origin: JobRecord.Origin = .user,
                     reason: String? = nil, target: String? = nil) -> JobRecord {
        JobRecord(id: id, name: "job-\(id)", image: "images.canfar.net/p/x:1", origin: origin, outcome: outcome,
                  status: outcome == .failed ? "Failed" : "Succeeded", startedAt: "2026-09-27T10:00:00Z",
                  finishedAt: Date(), failureReason: reason, targetImage: target)
    }

    func testTheNewestIsFirstAndEachJobIsThereOnce() {
        let history = JobHistoryStore(persistence: nil)
        history.record(job("a", .succeeded))
        history.record(job("b"))
        history.record(job("a", .succeeded))
        XCTAssertEqual(history.jobs.map(\.id), ["a", "b"])
        history.record(job(""))
        XCTAssertEqual(history.jobs.count, 2, "a job without an id is not one")
        for index in 0...JobHistoryStore.maxJobs { history.record(job("j\(index)")) }
        XCTAssertEqual(history.jobs.count, JobHistoryStore.maxJobs)
        history.clear()
        XCTAssertTrue(history.jobs.isEmpty)
    }

    /// The monitor sees a probe fail with only its status; the coordinator
    /// knows the image and why. Whichever comes second, both survive.
    func testALaterSightingKeepsWhatAnEarlierOneKnew() {
        let probe = job("p", origin: .imageProbe, reason: "Manifest missing after the job ended", target: "skaha/x:1")
        let sighting = HeadlessMonitorModel.record(of: HeadlessJob.failed(id: "p"))
        XCTAssertEqual(sighting.failureReason, "Failed")

        let history = JobHistoryStore(persistence: nil)
        history.record(probe)
        history.record(sighting)
        XCTAssertEqual(history.jobs.first?.origin, .imageProbe)
        XCTAssertEqual(history.jobs.first?.targetImage, "skaha/x:1")
        XCTAssertEqual(history.jobs.first?.failureReason, "Manifest missing after the job ended")
        XCTAssertEqual(history.jobs.first?.summary, "Image inspection — skaha/x:1")

        let other = JobHistoryStore(persistence: nil)
        other.record(sighting)
        other.record(probe)
        XCTAssertEqual(other.jobs.first?.failureReason, "Manifest missing after the job ended")
        XCTAssertEqual(other.jobs.first?.name, "job-p")
    }

    func testTheToolListsFailuresAlone() async throws {
        let jobs = [job("a", .succeeded), job("b", reason: "OOMKilled"), job("c")]
        let tool = ListJobHistoryTool(jobs: { jobs })
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        guard case .data(let data) = await tool.invoke(arguments: Data(#"{"failedOnly":true,"limit":1}"#.utf8), context: ctx) else {
            return XCTFail()
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["total"] as? Int, 2)
        let listed = try XCTUnwrap(object["jobs"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? String }, ["b"])
        XCTAssertEqual(listed.first?["failureReason"] as? String, "OOMKilled")
        XCTAssertEqual(listed.first?["origin"] as? String, "user")
    }
}

private extension HeadlessJob {
    static func failed(id: String) -> HeadlessJob {
        HeadlessJob(from: SkahaHeadlessResponse(
            id: id, userid: nil, image: "", type: "headless", status: "Failed", name: "", startTime: nil, expiryTime: nil,
            connectURL: nil, requestedRAM: nil, requestedCPUCores: nil, requestedGPUCores: nil, ramInUse: nil,
            cpuCoresInUse: nil, isFixedResources: nil))
    }
}
