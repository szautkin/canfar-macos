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
        var seenOffset: Int = -1
        var seenMax: Int = -1
        let tool = makeTool { _, offset, max in
            seenOffset = offset
            seenMax = max
            return ReadVOSpaceFetchResult(data: Data([0x41]), totalBytes: 1)
        }
        _ = try await tool.handle(args(), context: ctx())
        XCTAssertEqual(seenOffset, 0)
        XCTAssertEqual(seenMax, 256 * 1024, "default maxBytes must be 256 KB")
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

    // MARK: - inferContentType pure function

    func testInferContentTypeForCommonExtensions() {
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "a.fits"), "application/fits")
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "a.gz"), "application/gzip")
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "a.json"), "application/json")
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "a.py"), "text/x-python")
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "a.md"), "text/markdown")
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "deep/path/log.txt"), "text/plain")
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "no_extension"), "application/octet-stream")
    }

    /// Case-insensitive: `.FITS` and `.fits` must map to the same
    /// content-type. Astronomy filenames in the wild are wildly
    /// inconsistent on case.
    func testInferContentTypeCaseInsensitive() {
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "BIG.FITS"), "application/fits")
        XCTAssertEqual(ReadVOSpaceFileTool.inferContentType(path: "Notes.JSON"), "application/json")
    }
}
