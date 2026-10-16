// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 41 step 2: the platform load reads GPUs when the stats carry them,
/// in Skaha's shape or the Science Portal's, and none otherwise; each
/// refresh decides again.
@MainActor
final class PlatformLoadGPUTests: XCTestCase {

    private func stats(_ body: String) throws -> SkahaStatsResponse {
        try JSONDecoder().decode(SkahaStatsResponse.self, from: Data(body.utf8))
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// Today's production shape: no GPUs.
    private let production = #"""
    {"instances": {"session": 3, "desktopApp": 1, "headless": 2, "total": 6},
     "cores": {"requestedCPUCores": 1164.4, "cpuCoresAvailable": 3000},
     "ram": {"requestedRAM": "11847.667G", "ramAvailable": "15032.386G"}}
    """#

    // MARK: - Reading the stats

    func testStatsWithGPUsInSkahasShapeGiveTheGPULoad() throws {
        for gpus in [#"{"requestedGPUs": 20, "gpusAvailable": 112}"#,
                     #"{"requestedGPUCores": "20", "gpuCoresAvailable": "112"}"#] {
            let read = try stats(#"{"cores": {"requestedCPUCores": 1, "cpuCoresAvailable": 2}, "gpus": \#(gpus)}"#)
            XCTAssertEqual(read.gpu, GPUStats(used: 20, total: 112), gpus)
            XCTAssertEqual(read.gpuFieldsNotRead, [])
        }
    }

    /// The Science Portal's platform-load, as the person pasted it.
    func testStatsWithGPUsInThePortalsShapeGiveTheGPULoad() throws {
        var read = try stats(#"""
        {"cpu": {"name": "CPU", "used": 1164.4, "free": 1835.6},
         "ram": {"name": "RAM", "used": 11847.667, "free": 3184.72},
         "maxValues": {"cpu": 3000, "ram": 15032.386, "gpu": 112},
         "lastUpdate": "2026-10-16T23:10:16.870Z",
         "gpu": {"name": "GPU", "used": 20, "free": 92}}
        """#)
        XCTAssertEqual(read.gpu, GPUStats(used: 20, total: 112))
        read = try stats(#"{"gpu": {"used": 3, "free": 5}}"#)
        XCTAssertEqual(read.gpu, GPUStats(used: 3, total: 8), "without maxValues, used and free")
    }

    func testStatsWithoutGPUsGiveNoGPULoad() throws {
        let read = try stats(production)
        XCTAssertNil(read.gpu)
        XCTAssertEqual(read.gpuFieldsNotRead, [])
        XCTAssertEqual(read.cores?.cpuCoresAvailable, 3000)
    }

    func testNonsenseGPUNumbersGiveNoGPULoad() throws {
        for gpus in [#"{"requestedGPUs": 0, "gpusAvailable": 0}"#, #"{"requestedGPUs": 9, "gpusAvailable": 8}"#,
                     #"{"requestedGPUs": -1, "gpusAvailable": 8}"#, #"{"requestedGPUs": "many", "gpusAvailable": 8}"#] {
            XCTAssertNil(try stats(#"{"gpus": \#(gpus)}"#).gpu, gpus)
        }
    }

    /// GPU fields of a shape it does not read are named, for the tool, so
    /// the reader can be pinned once Skaha's are published.
    func testGPUFieldsOfAnotherShapeAreNamed() throws {
        var read = try stats(#"{"gpus": {"inUse": 3, "capacity": 8}}"#)
        XCTAssertNil(read.gpu)
        XCTAssertEqual(read.gpuFieldsNotRead, ["gpus.capacity", "gpus.inUse"])
        read = try stats(#"{"gpuCount": 4, "cores": {"requestedCPUCores": 1, "cpuCoresAvailable": 2}}"#)
        XCTAssertEqual(read.gpuFieldsNotRead, ["gpuCount"])
    }

    // MARK: - The model

    private func model(answering bodies: [String]) -> PlatformLoadModel {
        let queue = Queue(bodies)
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(queue.next().utf8))
        }
        return PlatformLoadModel(platformService: PlatformService(network: NetworkClient(session: MockURLProtocol.mockSession())))
    }

    private final class Queue: @unchecked Sendable {
        private var bodies: [String]
        private let lock = NSLock()
        init(_ bodies: [String]) { self.bodies = bodies }
        func next() -> String { lock.withLock { bodies.count > 1 ? bodies.removeFirst() : bodies[0] } }
    }

    func testTheGPULoadLightsUpWhenItArrives() async {
        let withGPUs = #"{"cores": {"requestedCPUCores": 1, "cpuCoresAvailable": 2}, "gpus": {"requestedGPUs": 20, "gpusAvailable": 112}}"#
        let load = model(answering: [production, withGPUs, production])
        await load.loadStats()
        XCTAssertNil(load.gpu)
        await load.loadStats()
        XCTAssertEqual(load.gpu?.used, 20)
        XCTAssertEqual(load.gpu?.free, 92)
        await load.loadStats()
        XCTAssertNil(load.gpu, "nothing is kept from an earlier refresh")
        XCTAssertNotNil(load.cpu)
    }

    func testPercentagesAreTheShareUsed() async throws {
        let load = model(answering: [#"""
        {"cores": {"requestedCPUCores": 1164.4, "cpuCoresAvailable": 3000},
         "ram": {"requestedRAM": "11847.667G", "ramAvailable": "15032.386G"},
         "gpus": {"requestedGPUs": 20, "gpusAvailable": 112}}
        """#])
        await load.loadStats()
        let cpu = try XCTUnwrap(load.cpu), ram = try XCTUnwrap(load.ram), gpu = try XCTUnwrap(load.gpu)
        XCTAssertEqual(cpu.percent, 38.81, accuracy: 0.01)
        XCTAssertEqual(ram.percent, 78.81, accuracy: 0.01)
        XCTAssertEqual(gpu.percent, 17.86, accuracy: 0.01)
        XCTAssertEqual(cpu.free, 1835.6, accuracy: 0.001)
    }

    func testAResourceTheStatsLeaveOutHasNoLoad() async {
        let load = model(answering: [#"{"cores": {"requestedCPUCores": 1, "cpuCoresAvailable": 0}}"#])
        await load.loadStats()
        XCTAssertNil(load.cpu, "a total of 0 is no numbers, not 0 %")
        XCTAssertNil(load.ram)
        XCTAssertNil(load.gpu)
    }

    // MARK: - get_platform_load

    private func toolJSON(_ body: String) async throws -> [String: Any] {
        let read = try stats(body)
        let tool = GetPlatformLoadTool(fetch: { GetPlatformLoadTool.Output(stats: read) })
        let ctx = AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))
        guard case .data(let data) = await tool.invoke(arguments: Data("{}".utf8), context: ctx) else {
            XCTFail("no data"); return [:]
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheToolGivesTheGPULoad() async throws {
        let json = try await toolJSON(#"{"gpus": {"requestedGPUs": 20, "gpusAvailable": 112}}"#)
        let gpu = try XCTUnwrap(json["gpu"] as? [String: Any])
        XCTAssertEqual(gpu["used"] as? Double, 20)
        XCTAssertEqual(gpu["free"] as? Double, 92)
        XCTAssertEqual(gpu["total"] as? Double, 112)
        XCTAssertEqual(gpu["percent"] as? Double, 17.9)
        XCTAssertNil(json["gpuNote"])
    }

    func testTheToolSaysWhenThereIsNoGPULoad() async throws {
        var json = try await toolJSON(production)
        XCTAssertTrue(json["gpu"] is NSNull, "gpu: null, said, not left out")
        XCTAssertEqual(json["gpuNote"] as? String, "This platform does not report GPUs.")
        json = try await toolJSON(#"{"gpus": {"inUse": 3, "capacity": 8}}"#)
        XCTAssertEqual(json["gpuNote"] as? String,
                       "The platform's stats have GPU fields Verbinal does not read yet: gpus.capacity, gpus.inUse.")
    }
}
