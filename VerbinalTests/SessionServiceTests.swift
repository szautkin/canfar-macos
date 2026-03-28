// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import XCTest
@testable import Verbinal

final class SessionServiceTests: XCTestCase {

    private func makeService() -> SessionService {
        SessionService(network: NetworkClient(session: MockURLProtocol.mockSession()))
    }

    private func capturedFormData(from request: URLRequest) -> [String: String] {
        guard let body = request.httpBody ?? readBodyStream(request),
              let str = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in str.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                result[key] = val
            }
        }
        return result
    }

    private func readBodyStream(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: 4096)
            guard read > 0 else { break }
            data.append(buf, count: read)
        }
        return data
    }

    // MARK: - Registry Prefix

    func testLaunchPrependsRegistryWhenMissing() async throws {
        let service = makeService()
        var captured: [String: String] = [:]

        MockURLProtocol.requestHandler = { request in
            captured = self.capturedFormData(from: request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"["sess-1"]"#.utf8))
        }

        var params = SessionLaunchParams(type: "contributed", name: "test1", image: "private-test/globus-ft:0.0.2")
        params.cores = 0
        _ = try await service.launchSession(params)

        XCTAssertEqual(captured["image"], "images.canfar.net/private-test/globus-ft:0.0.2")
    }

    func testLaunchKeepsFullRegistryPath() async throws {
        let service = makeService()
        var captured: [String: String] = [:]

        MockURLProtocol.requestHandler = { request in
            captured = self.capturedFormData(from: request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"["sess-1"]"#.utf8))
        }

        var params = SessionLaunchParams(type: "notebook", name: "nb1", image: "images.canfar.net/skaha/notebook:latest")
        params.cores = 0
        _ = try await service.launchSession(params)

        XCTAssertEqual(captured["image"], "images.canfar.net/skaha/notebook:latest")
    }

    // MARK: - Resource Type

    func testFlexibleSendsSharedResourceType() async throws {
        let service = makeService()
        var captured: [String: String] = [:]

        MockURLProtocol.requestHandler = { request in
            captured = self.capturedFormData(from: request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"["sess-1"]"#.utf8))
        }

        var params = SessionLaunchParams(type: "notebook", name: "nb1", image: "images.canfar.net/skaha/notebook:latest")
        params.cores = 0
        params.ram = 0
        _ = try await service.launchSession(params)

        XCTAssertEqual(captured["resourceType"], "shared")
        XCTAssertNil(captured["cores"])
        XCTAssertNil(captured["ram"])
        XCTAssertNil(captured["gpus"])
    }

    func testFixedSendsCustomResourceType() async throws {
        let service = makeService()
        var captured: [String: String] = [:]

        MockURLProtocol.requestHandler = { request in
            captured = self.capturedFormData(from: request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"["sess-1"]"#.utf8))
        }

        var params = SessionLaunchParams(type: "notebook", name: "nb1", image: "images.canfar.net/skaha/notebook:latest")
        params.cores = 4
        params.ram = 8
        params.gpus = 0
        _ = try await service.launchSession(params)

        XCTAssertEqual(captured["resourceType"], "custom")
        XCTAssertEqual(captured["cores"], "4")
        XCTAssertEqual(captured["ram"], "8")
        XCTAssertNil(captured["gpus"]) // gpus=0 should not be sent
    }

    func testFixedWithGPUsSendsGPUs() async throws {
        let service = makeService()
        var captured: [String: String] = [:]

        MockURLProtocol.requestHandler = { request in
            captured = self.capturedFormData(from: request)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"["sess-1"]"#.utf8))
        }

        var params = SessionLaunchParams(type: "notebook", name: "nb1", image: "images.canfar.net/skaha/notebook:latest")
        params.cores = 4
        params.ram = 16
        params.gpus = 1
        _ = try await service.launchSession(params)

        XCTAssertEqual(captured["gpus"], "1")
    }
}
