// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// Reading part of a file where it is (plan 47 3.1): the range a server
/// honours, the whole file a server sends instead, and past the end.
final class RangeReadTests: XCTestCase {
    private var client: NetworkClient!
    private let url = "https://ws-uv.canfar.net/arc/files/home/u/cube.fits"

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeStub.self]
        client = NetworkClient(session: URLSession(configuration: config))
        RangeStub.answer = nil
    }

    private static let file = Data((0..<10_000).map { UInt8($0 % 251) })

    func testAnHonouredRangeIsThoseBytesAndTheSize() async throws {
        RangeStub.answer = .partial
        let read = try await client.getRange(url, offset: 100, length: 50)
        XCTAssertTrue(read.honoredRange)
        XCTAssertEqual(read.data, Self.file[100..<150])
        XCTAssertEqual(read.totalBytes, 10_000)
        XCTAssertEqual(RangeStub.lastRange, "bytes=100-149")
    }

    func testTheWholeFileInsteadIsReadOnlyToTheLengthAsked() async throws {
        RangeStub.answer = .whole
        let read = try await client.getRange(url, offset: 0, length: 2880)
        XCTAssertFalse(read.honoredRange)
        XCTAssertEqual(read.data, Self.file.prefix(2880), "the start, and no more")
        XCTAssertEqual(read.totalBytes, 10_000)
    }

    func testTheWholeFileInsteadOfALaterRangeGivesNothing() async throws {
        RangeStub.answer = .whole
        let read = try await client.getRange(url, offset: 5000, length: 100)
        XCTAssertFalse(read.honoredRange)
        XCTAssertTrue(read.data.isEmpty, "not the file's start, which is not what was asked")
    }

    func testPastTheEndIsNoBytes() async throws {
        RangeStub.answer = .unsatisfiable
        let read = try await client.getRange(url, offset: 20_000, length: 10)
        XCTAssertTrue(read.data.isEmpty)
        XCTAssertEqual(read.totalBytes, 10_000)
    }

    func testAnErrorSaysItsStatus() async {
        RangeStub.answer = .missing
        do {
            _ = try await client.getRange(url, offset: 0, length: 10)
            XCTFail("a 404 is an error")
        } catch NetworkError.httpError(let status, _) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testARemoteSourceReadsAHeaderInOneRequestAndKeepsIt() async throws {
        let counter = Counter()
        let file = Self.file
        let source = RemoteCubeDataSource(name: "cube.fits", size: file.count, chunkSize: 4096) { offset, length in
            await counter.add()
            return file.subdata(in: offset..<min(offset + length, file.count))
        }
        let first = try await source.read(offset: 0, length: 2880)
        let second = try await source.read(offset: 2880, length: 1000)
        XCTAssertEqual(first, file[0..<2880])
        XCTAssertEqual(second, file[2880..<3880])
        let requests = await counter.count
        XCTAssertEqual(requests, 1, "both within the first chunk")
        let across = try await source.read(offset: 4000, length: 200)
        XCTAssertEqual(across, file[4000..<4200], "across two chunks")
        let big = try await source.read(offset: 0, length: 9000)
        XCTAssertEqual(big, file[0..<9000], "larger than a chunk: read as it is")
    }
}

private actor Counter {
    private(set) var count = 0
    func add() { count += 1 }
}

/// Answers as a server would for the file `RangeReadTests.file`.
private final class RangeStub: URLProtocol {
    enum Answer { case partial, whole, unsatisfiable, missing }
    nonisolated(unsafe) static var answer: Answer?
    nonisolated(unsafe) static var lastRange: String?
    private static let file = Data((0..<10_000).map { UInt8($0 % 251) })

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        Self.lastRange = range
        let file = Self.file
        let status: Int
        var headers = ["Content-Type": "application/fits"]
        var body = Data()
        switch Self.answer ?? .missing {
        case .partial:
            let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
            let lower = bounds[0], upper = min(bounds[1], file.count - 1)
            status = 206
            body = file[lower...upper]
            headers["Content-Range"] = "bytes \(lower)-\(upper)/\(file.count)"
        case .whole:
            status = 200
            body = file
            headers["Content-Length"] = "\(file.count)"
        case .unsatisfiable:
            status = 416
            headers["Content-Range"] = "bytes */\(file.count)"
        case .missing:
            status = 404
            body = Data("no such file".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
