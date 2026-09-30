// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Every request takes its patience from `RequestTimeout`, by kind.
final class RequestTimeoutTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// The kinds keep their order: a probe is quicker than a lookup, a
    /// lookup than an ordinary call, and a launch or a transfer waits at
    /// least as long as an ordinary call.
    func testTheKindsKeepTheirOrder() {
        XCTAssertLessThan(RequestTimeout.probe, RequestTimeout.lookup)
        XCTAssertLessThan(RequestTimeout.lookup, RequestTimeout.standard)
        XCTAssertGreaterThanOrEqual(RequestTimeout.launch, RequestTimeout.standard)
        XCTAssertGreaterThanOrEqual(RequestTimeout.transfer, RequestTimeout.standard)
    }

    /// A CADC call that names no timeout waits the standard one.
    func testAnOrdinaryCallWaitsTheStandardTimeout() async throws {
        var captured: TimeInterval?
        MockURLProtocol.requestHandler = { request in
            captured = request.timeoutInterval
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let network = NetworkClient(session: MockURLProtocol.mockSession())
        _ = try await network.get("https://ws-cadc.canfar.net/ac/whoami")
        XCTAssertEqual(captured, RequestTimeout.standard)
    }

    /// The registry's list of services is a lookup.
    func testTheRegistryIsALookup() async throws {
        var captured: TimeInterval?
        MockURLProtocol.requestHandler = { request in
            captured = request.timeoutInterval
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        _ = try await RegistryClient(session: MockURLProtocol.mockSession())
            .fetchResourceCaps(from: "https://cadc-west-01.canfar.net/reg/resource-caps")
        XCTAssertEqual(captured, RequestTimeout.lookup)
    }
}
