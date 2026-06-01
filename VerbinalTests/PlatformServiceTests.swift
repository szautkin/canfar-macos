// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Covers the single-object / array-wrapped / strict-decode fallback chain in
/// `PlatformService.getStats()`. A shift in the CADC stats response shape should
/// surface a clear, tested failure here rather than a silently-broken stats panel.
final class PlatformServiceTests: XCTestCase {

    private func makeService() -> PlatformService {
        PlatformService(network: NetworkClient(session: MockURLProtocol.mockSession()))
    }

    private func respond(_ body: String) {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (resp, Data(body.utf8))
        }
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Path 1: single object

    func testGetStatsDecodesSingleObject() async throws {
        let service = makeService()
        respond(#"""
        {
          "instances": {"session": 3, "desktopApp": 1, "headless": 2, "total": 6},
          "cores": {"requestedCPUCores": 12.5, "cpuCoresAvailable": 100.0},
          "ram": {"requestedRAM": "48G", "ramAvailable": "512G"}
        }
        """#)

        let stats = try await service.getStats()
        XCTAssertEqual(stats.instances?.total, 6)
        XCTAssertEqual(stats.cores?.requestedCPUCores, 12.5)
        XCTAssertEqual(stats.cores?.cpuCoresAvailable, 100.0)
        XCTAssertEqual(stats.ram?.requestedRAM, "48G")
    }

    // MARK: - Path 2: array-wrapped object -> array.first

    func testGetStatsReturnsFirstOfArrayWrappedResponse() async throws {
        let service = makeService()
        // First-path single-object decode fails on a JSON array, so the
        // array-decode branch must fire and return `array.first`.
        respond(#"""
        [
          {"cores": {"requestedCPUCores": 7.0, "cpuCoresAvailable": 64.0}},
          {"cores": {"requestedCPUCores": 1.0, "cpuCoresAvailable": 1.0}}
        ]
        """#)

        let stats = try await service.getStats()
        XCTAssertEqual(stats.cores?.requestedCPUCores, 7.0,
                       "Expected the first element of the array-wrapped response")
        XCTAssertEqual(stats.cores?.cpuCoresAvailable, 64.0)
    }

    // MARK: - Path 3: malformed JSON -> strict decode rethrows

    func testGetStatsRethrowsDecodingErrorForMalformedJSON() async {
        let service = makeService()
        respond("this is not json")

        do {
            _ = try await service.getStats()
            XCTFail("Expected a decoding error to propagate to the caller")
        } catch is DecodingError {
            // Expected: the final strict decode surfaces a clear error.
        } catch {
            XCTFail("Expected DecodingError, got \(error)")
        }
    }

    // MARK: - Path 3 (cont.): empty array -> strict decode fallback throws

    func testGetStatsThrowsForEmptyArray() async {
        let service = makeService()
        // The array decode succeeds but `array.first` is nil, so control
        // falls through to the strict single-object decode, which throws
        // because `[]` is not a SkahaStatsResponse object.
        respond("[]")

        do {
            _ = try await service.getStats()
            XCTFail("Expected the strict-decode fallback to throw on an empty array")
        } catch is DecodingError {
            // Expected.
        } catch {
            XCTFail("Expected DecodingError, got \(error)")
        }
    }
}
