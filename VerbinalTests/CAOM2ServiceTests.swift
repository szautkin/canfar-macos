// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Service-layer behaviours for ``CAOM2Service`` — verifies the request
/// shape (correct URL + ID param), HTTP-status branching (401/403→authRequired,
/// 404→notFound, 5xx→serverError), and the in-actor LRU cache.
final class CAOM2ServiceTests: XCTestCase {

    private static let publisherID = "ivo://cadc.nrc.ca/CFHT?22803/22803o"
    private static let expectedID = "caom:CFHT/22803"
    private static let validXML = #"""
    <?xml version="1.0"?>
    <caom2:Observation xmlns:caom2="http://www.opencadc.org/caom2/xml/v2.4">
      <caom2:collection>CFHT</caom2:collection>
      <caom2:observationID>22803</caom2:observationID>
    </caom2:Observation>
    """#

    private func makeService(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> CAOM2Service {
        MockURLProtocol.requestHandler = handler
        return CAOM2Service(session: MockURLProtocol.mockSession())
    }

    // MARK: - Request shape

    func testFetchSendsCAOM2ObservationURI() async throws {
        let receivedID = LockedString()
        let service = makeService { request in
            // Capture the ID query param so the test can pin the URI mapping.
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let idItem = comps?.queryItems?.first { $0.name == "ID" }
            receivedID.set(idItem?.value)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(Self.validXML.utf8)
            )
        }
        _ = try await service.fetch(publisherID: Self.publisherID)
        XCTAssertEqual(receivedID.value, Self.expectedID)
    }

    func testFetchInvalidPublisherIDThrows() async {
        let service = makeService { _ in
            (HTTPURLResponse(), Data())
        }
        do {
            _ = try await service.fetch(publisherID: "not-a-uri")
            XCTFail("Expected throw")
        } catch CAOM2ServiceError.invalidPublisherID {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - HTTP status branching

    func testFetchAuthRequiredOn401() async {
        let service = makeService { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data("Unauthorized".utf8)
            )
        }
        do {
            _ = try await service.fetch(publisherID: Self.publisherID)
            XCTFail("Expected throw")
        } catch CAOM2ServiceError.authenticationRequired {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testFetchAuthRequiredOn403() async {
        let service = makeService { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data("Forbidden".utf8)
            )
        }
        do {
            _ = try await service.fetch(publisherID: Self.publisherID)
            XCTFail("Expected throw")
        } catch CAOM2ServiceError.authenticationRequired {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testFetchNotFoundOn404() async {
        let service = makeService { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data("Not Found".utf8)
            )
        }
        do {
            _ = try await service.fetch(publisherID: Self.publisherID)
            XCTFail("Expected throw")
        } catch CAOM2ServiceError.observationNotFound {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testFetch500RaisesServerError() async {
        let service = makeService { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("oops".utf8)
            )
        }
        do {
            _ = try await service.fetch(publisherID: Self.publisherID)
            XCTFail("Expected throw")
        } catch CAOM2ServiceError.serverError(let status, let body) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "oops")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Cache

    func testFetchCachesResultsByObservationURI() async throws {
        let counter = LockedCounter()
        let service = makeService { request in
            counter.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(Self.validXML.utf8)
            )
        }
        _ = try await service.fetch(publisherID: Self.publisherID)
        _ = try await service.fetch(publisherID: Self.publisherID)
        XCTAssertEqual(counter.value, 1, "Second fetch should hit the LRU cache, not the network")
    }
}

// MARK: - Test helpers

/// Lock-guarded box. Uses `NSLock` rather than an actor so it's callable
/// from `MockURLProtocol`'s synchronous handler closure.
private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ s: String?) { lock.lock(); defer { lock.unlock() }; stored = s }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
