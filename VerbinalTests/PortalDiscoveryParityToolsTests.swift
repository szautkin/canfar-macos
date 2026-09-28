// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Unit coverage for the Portal + image-discovery parity batch
/// (session events/logs/connect, probe failures/logs/manifest, clear
/// failures). Stub closures — no network.
final class PortalDiscoveryParityToolsTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    private func argsData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func decodeJSON(_ result: ToolResult) throws -> [String: Any] {
        guard case .data(let data) = result else {
            XCTFail("expected .data, got \(result)")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - get_session_events / logs

    func testGetSessionEventsForwardsID() async throws {
        let tool = GetSessionEventsTool(fetch: { id in
            XCTAssertEqual(id, "s1"); return "Scheduled: pod assigned"
        })
        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["id": "s1"]), context: ctx()))
        XCTAssertEqual(json["events"] as? String, "Scheduled: pod assigned")
    }

    /// Plan 15 O3 (QA L15): the platform's `<none>` is no events, not an event.
    func testNoEventsIsEmpty() async throws {
        let tool = GetSessionEventsTool(fetch: { _ in "<none>\n" })
        let json = try decodeJSON(await tool.invoke(arguments: argsData(["id": "s1"]), context: ctx()))
        XCTAssertEqual(json["events"] as? String, "")
        XCTAssertEqual(json["hasEvents"] as? Bool, false)
    }

    /// QA L7 and L8: a launch's project comes from its image when it was not
    /// recorded, and a flexible session says so for cores and RAM.
    func testALaunchKnowsItsProjectAndAFlexibleSessionSaysSo() {
        XCTAssertEqual(ImageParser.project(of: "images.canfar.net/canucs/notebook:1.0"), "canucs")
        XCTAssertEqual(RecentLaunch(image: "images.canfar.net/astroai/notebook:latest").imageProject, "astroai")
        XCTAssertEqual(RecentLaunch(image: "images.canfar.net/astroai/notebook:latest", project: "skaha").imageProject, "skaha")

        let flexible = Session(from: SkahaSessionResponse(
            id: "xb0b7mu3", userid: nil, runAsUID: nil, runAsGID: nil, supplementalGroups: nil,
            image: "images.canfar.net/skaha/notebook:1", type: "notebook", status: "Running", name: "nb",
            startTime: "", expiryTime: "", connectURL: "", requestedRAM: nil, requestedCPUCores: nil,
            requestedGPUCores: nil, ramInUse: nil, cpuCoresInUse: nil, isFixedResources: false))
        XCTAssertEqual([flexible.coresGiven, flexible.ramGiven], ["flexible", "flexible"])
    }

    func testGetSessionLogsTailsLongOutput() async throws {
        let long = String(repeating: "x", count: 3000)
        let tool = GetSessionLogsTool(fetch: { _ in long })
        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["id": "s1", "tailBytes": 1024]), context: ctx()))
        XCTAssertEqual((json["logs"] as? String)?.utf8.count, 1024)
        XCTAssertEqual(json["truncated"] as? Bool, true)

        let short = GetSessionLogsTool(fetch: { _ in "hello" })
        let json2 = try decodeJSON(await short.invoke(
            arguments: argsData(["id": "s1"]), context: ctx()))
        XCTAssertEqual(json2["truncated"] as? Bool, false)
    }

    // MARK: - open_session

    func testOpenSessionMapsRejectionAndURL() async throws {
        let notRunning = OpenSessionTool(open: { _ in .rejected("Session 'x' is Pending, not Running") })
        let failed = await notRunning.invoke(arguments: argsData(["id": "x"]), context: ctx())
        guard case .failed = failed else { return XCTFail("expected .failed, got \(failed)") }

        let ok = OpenSessionTool(open: { id in
            XCTAssertEqual(id, "s2")
            return .opened("https://ws-uv.canfar.net/session/s2")
        })
        let json = try decodeJSON(await ok.invoke(arguments: argsData(["id": "s2"]), context: ctx()))
        XCTAssertEqual(json["connectURL"] as? String, "https://ws-uv.canfar.net/session/s2")
    }

    // MARK: - list_probe_failures

    func testListProbeFailuresReturnsEntries() async throws {
        let tool = ListProbeFailuresTool(snapshot: {
            [.init(imageID: "images.canfar.net/skaha/broken:1.0",
                   category: "job_timed_out",
                   message: "probe never reached terminal state",
                   attemptedAtISO: "2026-07-19T10:00:00Z",
                   jobID: "job-9")]
        })
        let json = try decodeJSON(await tool.invoke(arguments: Data("{}".utf8), context: ctx()))
        let failures = try XCTUnwrap(json["failures"] as? [[String: Any]])
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0]["category"] as? String, "job_timed_out")
        XCTAssertEqual(failures[0]["jobID"] as? String, "job-9")
    }

    // MARK: - get_probe_logs

    func testGetProbeLogsReturnsBothStreams() async throws {
        let tool = GetProbeLogsTool(fetch: { jobID in
            XCTAssertEqual(jobID, "job-9")
            return (logs: "stdout here", events: "Pulled image")
        })
        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["jobID": "job-9"]), context: ctx()))
        XCTAssertEqual(json["logs"] as? String, "stdout here")
        XCTAssertEqual(json["events"] as? String, "Pulled image")
    }

    // MARK: - get_image_manifest

    func testGetImageManifestSurfacesUnknownTarget() async {
        let tool = GetImageManifestTool(lookup: { _ in nil })
        let result = await tool.invoke(
            arguments: argsData(["image": "images.canfar.net/skaha/nope:1"]), context: ctx())
        guard case .failed(let reason) = result, case .unknownTarget = reason else {
            return XCTFail("expected unknownTarget, got \(result)")
        }
    }

    // MARK: - clear_probe_failures

    func testClearProbeFailuresPlanSummaries() async throws {
        let all = try await ClearProbeFailuresTool().plan(.init(image: nil), context: ctx())
        XCTAssertEqual(all.kind, "clear_probe_failures")
        XCTAssertTrue(all.summary.contains("all"))

        let one = try await ClearProbeFailuresTool().plan(
            .init(image: "images.canfar.net/skaha/broken:1.0"), context: ctx())
        XCTAssertTrue(one.summary.contains("broken:1.0"))
        let payload = try JSONDecoder().decode(ClearProbeFailuresTool.Payload.self, from: one.payload)
        XCTAssertEqual(payload.image, "images.canfar.net/skaha/broken:1.0")
    }
}
