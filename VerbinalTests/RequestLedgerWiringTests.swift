// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 23 L1: the network client and the registry record what they send.
final class RequestLedgerWiringTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func answering(_ status: Int) {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
    }

    func testTheNetworkClientRecordsEachRequest() async throws {
        answering(200)
        let ledger = RequestLedger()
        let network = NetworkClient(session: MockURLProtocol.mockSession(), ledger: ledger)
        _ = try await network.get(APIEndpoints().sessionsURL)
        let record = try XCTUnwrap(ledger.recent().last)
        XCTAssertEqual(record.service.id, "skaha")
        XCTAssertEqual(record.outcome, .ok)
        XCTAssertEqual(record.timeout, RequestTimeout.standard)
    }

    func testAFailedSignInIsRecordedAsSignInNeeded() async throws {
        answering(401)
        let ledger = RequestLedger()
        let auth = AuthService(network: NetworkClient(session: MockURLProtocol.mockSession(), ledger: ledger))
        _ = await auth.login(username: "someone", password: "wrong", rememberMe: false)
        XCTAssertEqual(ledger.recent().last?.service.id, "cadc-auth")
        XCTAssertEqual(ledger.recent().last?.outcome, .signInNeeded)
    }

    func testTheRegistryRecordsItsLookups() async throws {
        answering(503)
        let ledger = RequestLedger()
        let registry = RegistryClient(session: MockURLProtocol.mockSession(), ledger: ledger)
        _ = try? await registry.fetchResourceCaps(from: APIEndpoints().resourceCapsURL)
        XCTAssertEqual(ledger.recent().last?.service.id, "cadc-registry")
        XCTAssertEqual(ledger.recent().last?.outcome, .busy)
        XCTAssertEqual(ledger.recent().last?.timeout, RequestTimeout.lookup)
    }
}
