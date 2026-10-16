// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 41 step 1: the context is read defensively. GPUs missing, or in a
/// shape Verbinal does not know, are "no GPUs" — never a context lost, which
/// had cost the launch form its cores and RAM too.
final class SessionContextTests: XCTestCase {

    private func context(_ body: String) async throws -> SessionContext {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return try await ImageService(network: NetworkClient(session: MockURLProtocol.mockSession())).getContext()
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func list(_ range: ClosedRange<Int>) -> String { range.map(String.init).joined(separator: ", ") }

    private let coresAndMemory = #"""
    "cores": {"default": 2, "options": [1, 2, 4]}, "memoryGB": {"default": 8, "options": [4, 8, 16]}
    """#

    /// What staging sends (the person's paste, 2026-10-16), with the fields
    /// Verbinal does not read.
    func testStagingsContextDecodes() async throws {
        let read = try await context("""
        {"cores": {"default": 1, "defaultLimit": 16, "options": [\(list(1...32))], "defaultRequest": 1},
         "gpus": {"options": [\(list(1...7))]},
         "memoryGB": {"default": 4, "defaultLimit": 32, "options": [\(list(1...512))], "defaultRequest": 4},
         "maxInteractiveSessions": 3}
        """)
        XCTAssertEqual(read.gpuOffer, GPUOffer(counts: Array(1...7)))
        XCTAssertEqual(read.gpuOffer.largest, 7)
        XCTAssertEqual(read.cores.options.count, 32)
        XCTAssertEqual(read.memoryGB.options.last, 512)
        XCTAssertEqual(read.memoryGB.default, 4)
    }

    func testAContextWithoutGPUsStillGivesCoresAndMemory() async throws {
        let read = try await context("{\(coresAndMemory)}")
        XCTAssertEqual(read.gpuOffer, .none)
        XCTAssertEqual(read.cores.options, [1, 2, 4])
        XCTAssertEqual(read.memoryGB.default, 8)
    }

    func testAContextWithGPUsInAnotherShapeStillDecodes() async throws {
        for gpus in [#"null"#, #"{}"#, #"{"options": "1,2"}"#, #"[1, 2]"#, #"{"options": [1, "2"]}"#, #""4""#] {
            let read = try await context("{\(coresAndMemory), \"gpus\": \(gpus)}")
            XCTAssertEqual(read.gpuOffer, .none, gpus)
            XCTAssertEqual(read.cores.options, [1, 2, 4], gpus)
        }
    }

    func testOnlyZeroOffersNone() async throws {
        var read = try await context("{\(coresAndMemory), \"gpus\": {\"options\": [0]}}")
        XCTAssertEqual(read.gpuOffer, .none)
        XCTAssertFalse(read.gpuOffer.offersAny)
        read = try await context("{\(coresAndMemory), \"gpus\": {\"options\": [2, 0, 1, -1, 2]}}")
        XCTAssertEqual(read.gpuOffer, GPUOffer(counts: [1, 2]), "the positive counts, sorted, once each")
        XCTAssertTrue(read.gpuOffer.offersAny)
    }

    /// A batch job takes 0 or one of the counts offered; a gap is a gap.
    func testTheOfferAllowsZeroAndItsCounts() {
        let offer = GPUOffer(options: [1, 2, 4])
        XCTAssertTrue(offer.allows(0))
        XCTAssertTrue(offer.allows(4))
        XCTAssertFalse(offer.allows(3))
        XCTAssertFalse(offer.allows(5))
        XCTAssertTrue(GPUOffer.none.allows(0))
        XCTAssertFalse(GPUOffer.none.allows(1))
    }

    /// A cache written before plan 41 still reads, and one without GPUs
    /// writes and reads back.
    func testTheContextRoundTripsWithAndWithoutGPUs() throws {
        for gpus: GpuOptions? in [GpuOptions(options: [0, 1]), nil] {
            let original = SessionContext(cores: ResourceOptions(default: 2, options: [1, 2]),
                                          memoryGB: ResourceOptions(default: 4, options: [4, 8]), gpus: gpus)
            let back = try JSONDecoder().decode(SessionContext.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(back.gpuOffer, original.gpuOffer)
            XCTAssertEqual(back.cores.options, [1, 2])
        }
    }
}
