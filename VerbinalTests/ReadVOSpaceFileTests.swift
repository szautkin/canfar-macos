// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for `ReadVOSpaceFileTool` — the agent-visible bounded
/// read of a VOSpace file that closes the QA finding about
/// `download_from_vospace` delivering to the user's Mac (invisible
/// to the agent). Three of eight Skaha jobs in the documented
/// workflow existed only to work around that gap; the contract
/// below pins the boundary cases so future changes can't silently
/// regress.
final class ReadVOSpaceFileTests: XCTestCase {

    // MARK: - Test scaffolding

    private func makeTool(
        data: Data,
        totalBytes: Int? = nil
    ) -> ReadVOSpaceFileTool {
        ReadVOSpaceFileTool(fetch: { _, _, _ in
            ReadVOSpaceFetchResult(data: data, totalBytes: totalBytes)
        })
    }

    private func makeTool(
        respond: @escaping @Sendable (_ path: String, _ offset: Int, _ maxBytes: Int) -> ReadVOSpaceFetchResult
    ) -> ReadVOSpaceFileTool {
        ReadVOSpaceFileTool(fetch: { p, o, m in respond(p, o, m) })
    }

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 99)
        )
    }

    private func args(
        path: String = "data/file.bin",
        offset: Int? = nil,
        maxBytes: Int? = nil
    ) -> ReadVOSpaceFileTool.Args {
        ReadVOSpaceFileTool.Args(path: path, offset: offset, maxBytes: maxBytes)
    }

    // MARK: - Cap enforcement

    /// 1 MB is the documented hard cap per call. The boundary
    /// (1048576) must pass; one over must throw `invalidArgument`
    /// with guidance.
    func testHardCapBoundary() async throws {
        let tool = makeTool(data: Data(repeating: 0, count: 100))
        _ = try await tool.handle(args(maxBytes: 1024 * 1024), context: ctx())
    }

    func testOneByteOverHardCapRejected() async {
        let tool = makeTool(data: Data())
        do {
            _ = try await tool.handle(args(maxBytes: 1024 * 1024 + 1), context: ctx())
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            switch f {
            case .invalidArgument(let msg):
                XCTAssertTrue(msg.contains("1 MB"),
                              "must name the cap; got: \(msg)")
                XCTAssertTrue(msg.contains("download_from_vospace") || msg.contains("offset"),
                              "must point at the workaround; got: \(msg)")
            default:
                XCTFail("wrong typed case: \(f)")
            }
        } catch {
            XCTFail("expected ToolFailureReason; got \(error)")
        }
    }

    /// Negative offset is nonsensical and must be rejected upfront
    /// rather than handed to the service (which would build a
    /// malformed `Range:` header).
    func testNegativeOffsetRejected() async {
        let tool = makeTool(data: Data())
        do {
            _ = try await tool.handle(args(offset: -1), context: ctx())
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else {
                XCTFail("wrong typed case: \(f)")
                return
            }
        } catch {
            XCTFail("expected ToolFailureReason; got \(error)")
        }
    }

    func testZeroMaxBytesRejected() async {
        let tool = makeTool(data: Data())
        do {
            _ = try await tool.handle(args(maxBytes: 0), context: ctx())
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else {
                XCTFail("wrong typed case: \(f)")
                return
            }
        } catch {
            XCTFail("expected ToolFailureReason; got \(error)")
        }
    }

    // MARK: - Defaults

    /// Omitting `maxBytes` must default to 256 KB and omitting
    /// `offset` to 0 — pin these so future "let's be conservative"
    /// changes don't silently slash the per-call budget.
    func testDefaultsAreAppliedToServiceCall() async throws {
        let seen = Locked((offset: -1, max: -1))
        let tool = makeTool { _, offset, max in
            seen.set((offset, max))
            return ReadVOSpaceFetchResult(data: Data([0x41]), totalBytes: 1)
        }
        _ = try await tool.handle(args(), context: ctx())
        XCTAssertEqual(seen.value.offset, 0)
        XCTAssertEqual(seen.value.max, 256 * 1024, "default maxBytes must be 256 KB")
    }

    // MARK: - Encoding decisions

    /// Textual extension + valid UTF-8 bytes → UTF-8 encoding.
    func testTextualUTF8RidesAsString() async throws {
        let tool = makeTool(data: Data("hello\nworld".utf8), totalBytes: 11)
        let out = try await tool.handle(args(path: "notes/log.txt"), context: ctx())
        XCTAssertEqual(out.encoding, "utf8")
        XCTAssertEqual(out.content, "hello\nworld")
        XCTAssertEqual(out.contentType, "text/plain")
    }

    /// Textual extension but invalid UTF-8 (latin-1 byte 0xff) →
    /// base64 fallback.
    func testTextualExtensionWithBadUTF8FallsBackToBase64() async throws {
        let tool = makeTool(data: Data([0xFF, 0xFE, 0x01, 0x02]), totalBytes: 4)
        let out = try await tool.handle(args(path: "data/garbled.csv"), context: ctx())
        XCTAssertEqual(out.encoding, "base64")
        XCTAssertEqual(out.content, Data([0xFF, 0xFE, 0x01, 0x02]).base64EncodedString())
    }

    /// FITS / .gz / binary extensions ALWAYS ride base64 regardless
    /// of byte content — even if the bytes happen to parse as UTF-8.
    func testFITSExtensionAlwaysBase64() async throws {
        let tool = makeTool(data: Data("looks-like-text".utf8), totalBytes: 15)
        let out = try await tool.handle(args(path: "obs/cube.fits"), context: ctx())
        XCTAssertEqual(out.encoding, "base64",
                       "FITS must never be returned as utf8 even when the bytes happen to be ascii")
        XCTAssertEqual(out.contentType, "application/fits")
    }

    /// JSON files round-trip as utf8 — common case for results /
    /// manifests / config.
    func testJSONExtensionUTF8() async throws {
        let json = #"{"answer": 42}"#
        let tool = makeTool(data: Data(json.utf8), totalBytes: json.utf8.count)
        let out = try await tool.handle(args(path: "results/answer.json"), context: ctx())
        XCTAssertEqual(out.encoding, "utf8")
        XCTAssertEqual(out.content, json)
        XCTAssertEqual(out.contentType, "application/json")
    }

    /// Unknown extensions default to `application/octet-stream` and
    /// base64.
    func testUnknownExtensionBase64() async throws {
        let tool = makeTool(data: Data([0x01, 0x02, 0x03]))
        let out = try await tool.handle(args(path: "weird/thing.qqq"), context: ctx())
        XCTAssertEqual(out.encoding, "base64")
        XCTAssertEqual(out.contentType, "application/octet-stream")
    }

    /// Python / shell scripts must be utf8 — agents reading their
    /// own staged scripts back is a common debugging pattern.
    func testPythonAndShellAreUTF8() async throws {
        for path in ["scripts/job.py", "scripts/launch.sh"] {
            let body = "print('hi')\n"
            let tool = makeTool(data: Data(body.utf8), totalBytes: body.utf8.count)
            let out = try await tool.handle(args(path: path), context: ctx())
            XCTAssertEqual(out.encoding, "utf8", "\(path) must be utf8")
            XCTAssertEqual(out.content, body)
        }
    }

    // MARK: - Truncation flag

    /// When `totalBytes` is known and we got back fewer than the
    /// total, `truncated` is true.
    func testTruncatedTrueWhenServerReportsLargerTotal() async throws {
        let tool = makeTool(data: Data(repeating: 0x41, count: 100), totalBytes: 1000)
        let out = try await tool.handle(args(maxBytes: 100), context: ctx())
        XCTAssertEqual(out.totalBytes, 1000)
        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.returnedBytes, 100)
    }

    /// When totalBytes equals what we got back at offset 0 → not
    /// truncated.
    func testTruncatedFalseWhenWeGotEverything() async throws {
        let tool = makeTool(data: Data(repeating: 0x41, count: 50), totalBytes: 50)
        let out = try await tool.handle(args(maxBytes: 100), context: ctx())
        XCTAssertEqual(out.totalBytes, 50)
        XCTAssertFalse(out.truncated)
    }

    /// When totalBytes is nil and the response equals maxBytes
    /// exactly, conservatively flag `truncated` — caller can decide
    /// whether to keep paging.
    func testTruncatedTrueWhenSizeUnknownAndAtCap() async throws {
        let tool = makeTool(data: Data(repeating: 0x41, count: 100), totalBytes: nil)
        let out = try await tool.handle(args(maxBytes: 100), context: ctx())
        XCTAssertNil(out.totalBytes)
        XCTAssertTrue(out.truncated,
                      "must flag truncated when size unknown and we hit the cap exactly")
    }

    /// When totalBytes is nil and we got back less than maxBytes →
    /// we conservatively assume EOF (truncated = false). The
    /// alternative (always truncated when size is unknown) creates
    /// infinite-poll loops.
    func testTruncatedFalseWhenSizeUnknownAndUnderCap() async throws {
        let tool = makeTool(data: Data(repeating: 0x41, count: 50), totalBytes: nil)
        let out = try await tool.handle(args(maxBytes: 100), context: ctx())
        XCTAssertNil(out.totalBytes)
        XCTAssertFalse(out.truncated)
    }

    /// Offset + returned == total → not truncated (final chunk).
    func testFinalChunkAtOffsetNotTruncated() async throws {
        let tool = makeTool(data: Data(repeating: 0x41, count: 50), totalBytes: 100)
        let out = try await tool.handle(args(offset: 50, maxBytes: 100), context: ctx())
        XCTAssertEqual(out.totalBytes, 100)
        XCTAssertFalse(out.truncated, "offset 50 + 50 bytes = total 100; final chunk")
    }

    // MARK: - One media-type rule (VOSpaceContentType)

    func testContentTypeForCommonExtensions() {
        let type = { VOSpaceContentType.of(path: $0, stated: nil) }
        XCTAssertEqual(type("a.fits"), "application/fits")
        XCTAssertEqual(type("a.gz"), "application/gzip")
        XCTAssertEqual(type("a.json"), "application/json")
        XCTAssertEqual(type("a.py"), "text/x-python")
        XCTAssertEqual(type("a.md"), "text/markdown")
        XCTAssertEqual(type("deep/path/log.txt"), "text/plain")
        XCTAssertEqual(type("no_extension"), "application/octet-stream")
    }

    /// Case-insensitive: `.FITS` and `.fits` must map to the same
    /// content-type. Astronomy filenames in the wild are wildly
    /// inconsistent on case.
    func testContentTypeCaseInsensitive() {
        XCTAssertEqual(VOSpaceContentType.of(path: "BIG.FITS", stated: nil), "application/fits")
        XCTAssertEqual(VOSpaceContentType.of(path: "Notes.JSON", stated: nil), "application/json")
    }

    /// QA L5: a listing called a `.py` `application/octet-stream` (the
    /// server's word) and a read called it `text/x-python`.
    func testAListingAndAReadGiveAFileOneType() async throws {
        let listed = VOSpaceNode(name: "fit.py", path: "fit.py", type: .dataNode, contentType: "application/octet-stream")
        let tool = makeTool { _, _, _ in
            ReadVOSpaceFetchResult(data: Data("x = 1".utf8), totalBytes: 5, statedContentType: "application/octet-stream")
        }
        let read = try await tool.handle(args(path: "fit.py"), context: ctx())
        XCTAssertEqual(listed.mediaType, "text/x-python")
        XCTAssertEqual(read.contentType, listed.mediaType)
        XCTAssertEqual(read.encoding, "utf8")
        XCTAssertEqual(VOSpaceContentType.of(path: "run.slurm", stated: "text/plain"), "text/plain",
                       "an extension that names nothing takes the server's type")
        XCTAssertNil(VOSpaceNode(name: "results", path: "results", type: .container).mediaType)
    }

    /// Plan 17 G5 (QA L5): `.bashrc` has no extension, so the server's
    /// `octet-stream` stood; a dotfile is a settings file, text.
    func testADotfileIsText() {
        let stated = "application/octet-stream"
        XCTAssertEqual(VOSpaceContentType.of(path: "home/me/.bashrc", stated: stated), "text/plain")
        XCTAssertEqual(VOSpaceContentType.of(path: ".token", stated: nil), "text/plain")
        XCTAssertEqual(VOSpaceContentType.of(path: ".config.yaml", stated: stated), "application/yaml", "its extension first")
        XCTAssertEqual(VOSpaceContentType.of(path: "home/me/.DS_Store", stated: stated), stated)
        XCTAssertEqual(VOSpaceContentType.of(path: ".Xauthority", stated: nil), "application/octet-stream")
        XCTAssertEqual(VOSpaceContentType.of(path: ".", stated: nil), "application/octet-stream")
        XCTAssertEqual(VOSpaceNode(name: ".bashrc", path: "home/me/.bashrc", type: .dataNode, contentType: stated).mediaType,
                       "text/plain")
    }

    // MARK: - A server that ignores Range (QA H4)

    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://ws-uv.canfar.net/arc/files/home/u/notes.md")!,
                        statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    /// The reported case: a 445-byte file, `offset` 21, `maxBytes` 10,
    /// answered 200 with the whole file, gave bytes 0–9.
    func testAWholeFileAnswerIsReadFromTheOffset() {
        let file = Data((0..<445).map { UInt8($0 % 251) })
        let slice = VOSpaceBrowserService.slice(file, of: response(200, ["Content-Type": "text/markdown"]),
                                                offset: 21, maxBytes: 10)
        XCTAssertEqual(slice.data, file.subdata(in: 21..<31))
        XCTAssertEqual(slice.totalBytes, 445)
        XCTAssertEqual(slice.statedContentType, "text/markdown")

        let last = VOSpaceBrowserService.slice(file, of: response(200), offset: 440, maxBytes: 10)
        XCTAssertEqual(last.data, file.subdata(in: 440..<445))
        XCTAssertTrue(VOSpaceBrowserService.slice(file, of: response(200), offset: 445, maxBytes: 10).data.isEmpty)
    }

    func testARangedAnswerIsTheSlice() {
        let slice = VOSpaceBrowserService.slice(Data(repeating: 7, count: 10),
                                                of: response(206, ["Content-Range": "bytes 21-30/445"]),
                                                offset: 21, maxBytes: 10)
        XCTAssertEqual(slice.data, Data(repeating: 7, count: 10))
        XCTAssertEqual(slice.totalBytes, 445)
    }

    /// Reading a file in chunks reaches its end, whatever the server does with Range.
    func testChunkedReadsWalkTheFile() async throws {
        let file = Data((0..<445).map { UInt8($0 % 251) })
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, file)
        }
        defer { MockURLProtocol.requestHandler = nil }
        let service = VOSpaceBrowserService(network: NetworkClient(session: MockURLProtocol.mockSession()))
        var read = Data()
        var offset = 0
        for _ in 0..<10 {   // 445 bytes in 100s: five reads
            let chunk = try await service.fetchBytes(username: "u", path: "notes.md", offset: offset, maxBytes: 100)
            read += chunk.data
            offset += chunk.data.count
            if chunk.data.isEmpty || offset >= (chunk.totalBytes ?? .max) { break }
        }
        XCTAssertEqual(read, file)
    }

    // MARK: - A listing says when it stopped at its limit (QA L6)

    func testAListingSaysWhenItStoppedAtItsLimit() async throws {
        func node(_ i: Int) -> VOSpaceNodeOut {
            VOSpaceNodeOut(name: "f\(i)", path: "f\(i)", type: "dataNode", sizeBytes: 1, contentType: nil,
                           lastModified: nil, isPublic: false)
        }
        let folder = (0..<5).map(node)
        let tool = ListVOSpacePathTool(listNodes: { _, limit in Array(folder.prefix(limit)) })
        let first = try await tool.handle(.init(path: "", limit: 3), context: ctx())
        XCTAssertEqual(first.nodes.count, 3)
        XCTAssertTrue(first.truncated)
        let all = try await tool.handle(.init(path: "", limit: 5), context: ctx())
        XCTAssertEqual(all.nodes.count, 5)
        XCTAssertFalse(all.truncated)
    }
}
