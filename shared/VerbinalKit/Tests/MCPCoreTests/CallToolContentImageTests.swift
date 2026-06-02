// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

/// Verifies the inline-image content block: `CallToolContent.image` must encode
/// to the MCP `{ "type": "image", "data": <base64>, "mimeType": ... }` shape so
/// server-side fetch tools (get_preview_image) can return a displayable image.
final class CallToolContentImageTests: XCTestCase {

    private func encodeToObject(_ block: CallToolContent) throws -> [String: Any] {
        let data = try JSONEncoder().encode(block)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testImageEncodesAsMCPImageBlock() throws {
        let obj = try encodeToObject(.image(base64: "R0lGODdh", mimeType: "image/gif"))
        XCTAssertEqual(obj["type"] as? String, "image")
        XCTAssertEqual(obj["data"] as? String, "R0lGODdh")
        XCTAssertEqual(obj["mimeType"] as? String, "image/gif")
    }

    func testTextStillEncodesAsTextBlock() throws {
        let obj = try encodeToObject(.text("hello"))
        XCTAssertEqual(obj["type"] as? String, "text")
        XCTAssertEqual(obj["text"] as? String, "hello")
    }

    func testImageBlockRoundTripsThroughCallToolResult() throws {
        let result = CallToolResult(
            content: [.image(base64: "iVBORw0KGgo", mimeType: "image/png"), .text("preview.png")],
            isError: false
        )
        let data = try JSONEncoder().encode(result)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual(content[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(content[1]["type"] as? String, "text")
    }
}
