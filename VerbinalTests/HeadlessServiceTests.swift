// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Pin the wire shape `HeadlessService.launchHeadlessJob` produces
/// against Skaha's expectations and the canonical Python `canfar`
/// client. If these tests drift, agents and the in-app form will
/// silently produce malformed launches that Skaha rejects with
/// opaque 400s.
final class HeadlessServiceTests: XCTestCase {

    private func makeService() -> HeadlessService {
        HeadlessService(network: NetworkClient(session: MockURLProtocol.mockSession()))
    }

    private func okResponse(_ body: String = "session-abc-123\n") -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://ws-uv.canfar.net/skaha/v1/session")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(body.utf8))
    }

    /// Capture the form body of every POST so we can assert against
    /// it. URLSession's MockURLProtocol drops `httpBody` on the
    /// inbound request — we intercept via `bodyStreamForBody` instead.
    private func bodyString(_ request: URLRequest) -> String {
        if let bytes = request.httpBody {
            return String(data: bytes, encoding: .utf8) ?? ""
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }

    // MARK: - Single-replica wire shape

    func testLaunchSingleReplicaSendsExpectedFormFields() async throws {
        let service = makeService()
        var capturedBody = ""

        MockURLProtocol.requestHandler = { request in
            capturedBody = self.bodyString(request)
            return self.okResponse("xyz789\n")
        }

        let params = HeadlessLaunchParams(
            name: "smoke-job",
            image: "images.canfar.net/skaha/terminal:1.1.2",
            cmd: "echo hello",
            args: "--verbose",
            env: [("FOO", "bar")],
            cores: 2,
            ram: 8,
            gpus: 0,
            replicas: 1
        )

        let ids = try await service.launchHeadlessJob(params)
        XCTAssertEqual(ids, ["xyz789"])

        XCTAssertTrue(capturedBody.contains("type=headless"), "body: \(capturedBody)")
        XCTAssertTrue(capturedBody.contains("name=smoke-job"))
        XCTAssertTrue(capturedBody.contains("image=images.canfar.net/skaha/terminal:1.1.2") ||
                      capturedBody.contains("image=images.canfar.net%2Fskaha%2Fterminal%3A1.1.2"))
        XCTAssertTrue(capturedBody.contains("cmd=echo%20hello"))
        XCTAssertTrue(capturedBody.contains("args=--verbose"))
        XCTAssertTrue(capturedBody.contains("cores=2"))
        XCTAssertTrue(capturedBody.contains("ram=8"))
        // gpus=0 is omitted (matches in-app launch convention).
        XCTAssertFalse(capturedBody.contains("gpus="))
        // env: user var + auto-injected REPLICA_ID + REPLICA_COUNT.
        XCTAssertTrue(capturedBody.contains("env=FOO%3Dbar"))
        XCTAssertTrue(capturedBody.contains("env=REPLICA_ID%3D1"))
        XCTAssertTrue(capturedBody.contains("env=REPLICA_COUNT%3D1"))
        // replicas form field is NOT sent for count == 1 (matches
        // Python client behaviour: it only sends replicas when > 1).
        XCTAssertFalse(capturedBody.contains("replicas="))
    }

    // MARK: - Multi-replica loop

    func testLaunchThreeReplicasIssuesThreePostsWithIncrementalNames() async throws {
        let service = makeService()
        var capturedNames: [String] = []
        var capturedReplicaIDs: [String] = []
        var sequenceNumber = 0
        let lock = NSLock()

        MockURLProtocol.requestHandler = { request in
            let body = self.bodyString(request)
            // Pull out the replicaName and the REPLICA_ID injected per request
            if let nameMatch = body.range(of: "name=([^&]+)", options: .regularExpression) {
                let v = String(body[nameMatch]).replacingOccurrences(of: "name=", with: "")
                lock.lock(); capturedNames.append(v); lock.unlock()
            }
            if let idMatch = body.range(of: "REPLICA_ID%3D([0-9]+)", options: .regularExpression) {
                let v = String(body[idMatch]).replacingOccurrences(of: "env=REPLICA_ID%3D", with: "")
                                              .replacingOccurrences(of: "REPLICA_ID%3D", with: "")
                lock.lock(); capturedReplicaIDs.append(v); lock.unlock()
            }
            lock.lock()
            sequenceNumber += 1
            let id = sequenceNumber
            lock.unlock()
            return self.okResponse("job-\(id)\n")
        }

        let params = HeadlessLaunchParams(
            name: "batch",
            image: "images.canfar.net/skaha/terminal:1.1.2",
            cmd: "true",
            replicas: 3
        )

        let ids = try await service.launchHeadlessJob(params)
        XCTAssertEqual(ids, ["job-1", "job-2", "job-3"])
        XCTAssertEqual(capturedNames.sorted(), ["batch-1", "batch-2", "batch-3"])
        XCTAssertEqual(capturedReplicaIDs.sorted(), ["1", "2", "3"])
    }

    // MARK: - Partial failure

    func testReplicaFailureMidLoopThrowsPartialErrorWithLaunchedIDs() async throws {
        let service = makeService()
        var attempt = 0
        let lock = NSLock()

        MockURLProtocol.requestHandler = { _ in
            lock.lock()
            attempt += 1
            let n = attempt
            lock.unlock()
            if n == 3 {
                return (
                    HTTPURLResponse(
                        url: URL(string: "https://ws-uv.canfar.net/skaha/v1/session")!,
                        statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data("kaboom".utf8)
                )
            }
            return self.okResponse("ok-\(n)\n")
        }

        let params = HeadlessLaunchParams(
            name: "batch",
            image: "images.canfar.net/skaha/terminal:1.1.2",
            cmd: "true",
            replicas: 5
        )

        do {
            _ = try await service.launchHeadlessJob(params)
            XCTFail("expected partial failure")
        } catch let HeadlessLaunchError.partialReplicaFailure(launchedIDs, failedAt, _) {
            // Replicas 0 and 1 succeeded → "ok-1", "ok-2"; replica 2 (3rd) failed.
            XCTAssertEqual(launchedIDs, ["ok-1", "ok-2"])
            XCTAssertEqual(failedAt, 2)
        } catch {
            XCTFail("expected partialReplicaFailure, got \(error)")
        }
    }

    // MARK: - Empty optionals

    func testEmptyCmdAndArgsAreOmittedFromBody() async throws {
        let service = makeService()
        var capturedBody = ""

        MockURLProtocol.requestHandler = { request in
            capturedBody = self.bodyString(request)
            return self.okResponse()
        }

        let params = HeadlessLaunchParams(
            name: "no-cmd",
            image: "images.canfar.net/skaha/terminal:1.1.2",
            cmd: "",
            args: nil
        )
        _ = try await service.launchHeadlessJob(params)

        XCTAssertFalse(capturedBody.contains("cmd="), "body: \(capturedBody)")
        XCTAssertFalse(capturedBody.contains("args="), "body: \(capturedBody)")
    }
}
