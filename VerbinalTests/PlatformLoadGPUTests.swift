// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 41 step 2, plan 42 step 1: the platform load reads GPUs when Skaha's
/// stats carry its `gpu` block — `requestedGPU`, `gpuAvailable`, `maxGPU` —
/// and none otherwise; each refresh decides again.
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

    /// Skaha's block, as science-portal 2026.3's server reads it (plan 42).
    private let staging = #"{"cores": {"requestedCPUCores": 873.25, "cpuCoresAvailable": 3000}, "gpu": {"requestedGPU": 15, "gpuAvailable": 112, "maxGPU": 7}}"#

    func testSkahasGPUBlockGivesTheGPULoad() throws {
        let read = try stats(staging)
        XCTAssertEqual(read.gpu, GPUStats(used: 15, total: 112, perSession: 7))
        XCTAssertEqual(read.gpuFieldsNotRead, [])
        let strings = try stats(#"{"gpu": {"requestedGPU": "15", "gpuAvailable": "112", "maxGPU": "7"}}"#)
        XCTAssertEqual(strings.gpu, GPUStats(used: 15, total: 112, perSession: 7), "numeric strings")
        let noMax = try stats(#"{"gpu": {"requestedGPU": 15, "gpuAvailable": 112}}"#)
        XCTAssertEqual(noMax.gpu, GPUStats(used: 15, total: 112, perSession: nil), "maxGPU when it is there")
    }

    func testStatsWithoutGPUsGiveNoGPULoad() throws {
        let read = try stats(production)
        XCTAssertNil(read.gpu)
        XCTAssertEqual(read.gpuFieldsNotRead, [])
        XCTAssertEqual(read.cores?.cpuCoresAvailable, 3000)
        let null = try stats(#"{"gpu": null}"#)
        XCTAssertNil(null.gpu)
        XCTAssertEqual(null.gpuFieldsNotRead, [], "null: the cluster does not report GPUs")
    }

    func testAnIncompleteBlockGivesNoGPULoadAndIsNamed() throws {
        for gpu in [#"{"requestedGPU": 1, "gpuAvailable": "many", "maxGPU": 1}"#, #"{"requestedGPU": 1, "maxGPU": 1}"#] {
            let read = try stats(#"{"gpu": \#(gpu)}"#)
            XCTAssertNil(read.gpu, gpu)
            XCTAssertFalse(read.gpuFieldsNotRead.isEmpty, gpu)
        }
    }

    func testNonsenseGPUNumbersGiveNoGPULoad() throws {
        for gpu in [#"{"requestedGPU": 0, "gpuAvailable": 0}"#, #"{"requestedGPU": 9, "gpuAvailable": 8}"#,
                    #"{"requestedGPU": -1, "gpuAvailable": 8}"#] {
            XCTAssertNil(try stats(#"{"gpu": \#(gpu)}"#).gpu, gpu)
        }
    }

    /// Plan 41 guessed: a `gpus` key, names by prefix and suffix, and the
    /// Next.js summary's used/free. Skaha sends none of them; they are no
    /// longer read, and are named for the tool.
    func testTheGuessedShapesAreNoLongerRead() throws {
        var read = try stats(#"{"gpus": {"requestedGPUs": 20, "gpusAvailable": 112}}"#)
        XCTAssertNil(read.gpu)
        XCTAssertEqual(read.gpuFieldsNotRead, ["gpus.gpusAvailable", "gpus.requestedGPUs"])
        read = try stats(#"{"gpu": {"name": "GPU", "used": 20, "free": 92}, "maxValues": {"gpu": 112}}"#)
        XCTAssertNil(read.gpu)
        XCTAssertEqual(read.gpuFieldsNotRead, ["gpu.free", "gpu.name", "gpu.used"])
        read = try stats(#"{"gpu": {"requestedGPUCores": 20, "gpuCoresAvailable": 112}}"#)
        XCTAssertNil(read.gpu, "names by prefix and suffix are not Skaha's")
    }

    func testGPUFieldsOfAnotherShapeAreNamed() throws {
        let read = try stats(#"{"gpuCount": 4, "cores": {"requestedCPUCores": 1, "cpuCoresAvailable": 2}}"#)
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
        let withGPUs = #"{"cores": {"requestedCPUCores": 1, "cpuCoresAvailable": 2}, "gpu": {"requestedGPU": 20, "gpuAvailable": 112, "maxGPU": 7}}"#
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
         "gpu": {"requestedGPU": 20, "gpuAvailable": 112, "maxGPU": 7}}
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
        let json = try await toolJSON(#"{"gpu": {"requestedGPU": 20, "gpuAvailable": 112, "maxGPU": 7}}"#)
        let gpu = try XCTUnwrap(json["gpu"] as? [String: Any])
        XCTAssertEqual(gpu["used"] as? Double, 20)
        XCTAssertEqual(gpu["free"] as? Double, 92)
        XCTAssertEqual(gpu["total"] as? Double, 112)
        XCTAssertEqual(gpu["percent"] as? Double, 17.9)
        XCTAssertEqual(gpu["perSession"] as? Int, 7, "the most for one session")
        XCTAssertNil(json["gpuNote"])
    }

    func testTheToolSaysWhenThereIsNoGPULoad() async throws {
        var json = try await toolJSON(production)
        XCTAssertTrue(json["gpu"] is NSNull, "gpu: null, said, not left out")
        XCTAssertEqual(json["gpuNote"] as? String, "This platform does not report GPUs.")
        json = try await toolJSON(#"{"gpu": {"inUse": 3, "capacity": 8}}"#)
        XCTAssertEqual(json["gpuNote"] as? String,
                       "The platform's stats have GPU fields Verbinal does not read yet: gpu.capacity, gpu.inUse.")
    }
}
