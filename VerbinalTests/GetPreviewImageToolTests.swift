// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Unit coverage for `get_preview_image`: each failure mode the spec calls out
/// is designed out and pinned. Uses stub resolver/fetcher closures — no network.
final class GetPreviewImageToolTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    private let gifBytes = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00]) // "GIF89a.."
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    private func artifact(band: String?, ct: String? = "image/gif", len: Int64? = nil, name: String = "p.gif") -> GetPreviewImageTool.PreviewArtifact {
        .init(band: band, url: URL(string: "https://ws.cadc/data/pub/x")!, contentType: ct, contentLength: len, filename: name)
    }

    private func argsData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func makeTool(
        resolve: @escaping @Sendable (String) async throws -> [GetPreviewImageTool.PreviewArtifact],
        fetch: @escaping @Sendable (URL, Int) async throws -> (data: Data, contentType: String?)
    ) -> GetPreviewImageTool {
        GetPreviewImageTool(resolvePreviews: resolve, fetchImage: fetch)
    }

    // MARK: - Success

    func testReturnsInlineImageWithLeanMetadata() async throws {
        let gif = gifBytes
        let tool = makeTool(
            resolve: { [a = artifact(band: "G.MP9401")] _ in [a] },
            fetch: { _, _ in (gif, "image/gif") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x", "band": "G.MP9401"]), context: ctx())
        guard case .image(let data, let mime, let caption) = result else {
            return XCTFail("expected .image, got \(result)")
        }
        XCTAssertEqual(data, gif)
        XCTAssertEqual(mime, "image/gif")
        // Decode the metadata JSON (robust to JSON escaping/formatting).
        let capData = try XCTUnwrap(caption?.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: capData) as? [String: Any])
        XCTAssertEqual(obj["contentType"] as? String, "image/gif")
        XCTAssertEqual(obj["band"] as? String, "G.MP9401")
        XCTAssertEqual(obj["byteSize"] as? Int, gif.count)
        XCTAssertNil(obj["data"],
                     "image rides in the MCP image block; it must NOT be duplicated as base64 in the caption — that doubled the payload past Claude Desktop's ~1 MB response limit")
    }

    func testOversizeFetchedImageIsPreviewTooLarge() async {
        // No declared Content-Length, but the fetched bytes exceed the
        // MCP-safe cap → must be refused so the base64 response can never blow
        // the ~1 MB client limit. Valid GIF magic so it passes the type check
        // and trips the size guard, not contentTypeMismatch.
        var bigGif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])   // "GIF89a"
        bigGif.append(Data(repeating: 0x00, count: 800 * 1024))   // 800 KB > the ~696 KB cap
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: nil)] },
            fetch: { _, _ in (bigGif, "image/gif") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x"]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "previewTooLarge")
    }

    func testNoBandPicksFirstPreview() async {
        let png = pngBytes
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: "U.MP9301", ct: "image/png", name: "u.png"),
                             self.artifact(band: "G.MP9401")] },
            fetch: { _, _ in (png, "image/png") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x"]), context: ctx())
        guard case .image(_, let mime, _) = result else { return XCTFail("expected .image") }
        XCTAssertEqual(mime, "image/png", "picks the first preview when no band is given")
    }

    func testJpegPreviewIsRecognised() async {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] as [UInt8])
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: nil, ct: "image/jpeg", name: "p.jpg")] },
            fetch: { _, _ in (jpeg, "image/jpeg") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x"]), context: ctx())
        guard case .image(_, let mime, _) = result else { return XCTFail("expected .image") }
        XCTAssertEqual(mime, "image/jpeg")
    }

    func testArbitraryDeclaredImageTypeWithBinaryBytesIsAccepted() async {
        // Unknown magic + binary (invalid-UTF8) bytes + declared image/jp2 → trust it.
        let bytes = Data([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0xFF, 0xFE, 0x01] as [UInt8])
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: nil, ct: "image/jp2", name: "p.jp2")] },
            fetch: { _, _ in (bytes, "image/jp2") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x"]), context: ctx())
        guard case .image(_, let mime, _) = result else { return XCTFail("expected .image, got \(result)") }
        XCTAssertEqual(mime, "image/jp2", "an arbitrary image/* type with binary bytes is accepted")
    }

    // MARK: - Resolution failures

    func testBandWithNoPreviewListsAvailableBands() async {
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: "U.MP9301"), self.artifact(band: "G.MP9401")] },
            fetch: { _, _ in (self.gifBytes, "image/gif") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x", "band": "R.MP9999"]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "previewNotFound")
        XCTAssertTrue(reason.description.contains("G.MP9401") && reason.description.contains("U.MP9301"),
                      "lists the bands that DO have previews")
    }

    func testNoImagePreviewsAtAllIsPreviewNotFound() async {
        // resolver returns only a science FITS — must NOT be substituted.
        let tool = makeTool(
            resolve: { _ in [.init(band: nil, url: URL(string: "https://ws.cadc/sci.fits")!,
                                   contentType: "application/fits", contentLength: 400_000_000, filename: "sci.fits")] },
            fetch: { _, _ in (self.gifBytes, "image/gif") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x"]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "previewNotFound")
    }

    // MARK: - Size cap

    func testContentLengthOverCapIsPreviewTooLarge() async {
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: nil, len: 10_000_000)] },
            fetch: { _, _ in (self.gifBytes, "image/gif") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x", "max_bytes": 1_000_000]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "previewTooLarge")
    }

    // MARK: - Fetch failures

    func testAuthRequiredFromFetcher() async {
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: nil)] },
            fetch: { _, _ in throw GetPreviewImageTool.PreviewFetchError.http(403) }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x"]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "authRequired")
    }

    func testNonImageBodyIsContentTypeMismatch() async {
        // The exact failure we saw: a 403 "host_not_allowed" text body shipped
        // where image bytes were expected.
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: nil)] },
            fetch: { _, _ in (Data("Host not in allowlist".utf8), "image/gif") }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x"]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "contentTypeMismatch")
    }

    func testFetchTimeoutIsUpstreamTimeout() async {
        let tool = makeTool(
            resolve: { _ in [self.artifact(band: nil)] },
            fetch: { _, _ in throw GetPreviewImageTool.PreviewFetchError.timedOut }
        )
        let result = await tool.invoke(arguments: argsData(["publisher_id": "ivo://x"]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "upstreamTimeout")
    }

    // MARK: - Argument validation

    func testEmptyPublisherIDIsInvalidArgument() async {
        let tool = makeTool(resolve: { _ in [] }, fetch: { _, _ in (self.gifBytes, nil) })
        let result = await tool.invoke(arguments: argsData(["publisher_id": "  "]), context: ctx())
        guard case .failed(let reason) = result else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "invalidArgument")
    }
}
