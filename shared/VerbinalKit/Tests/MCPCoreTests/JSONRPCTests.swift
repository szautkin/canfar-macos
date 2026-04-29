// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

final class JSONRPCTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - ID round-trip

    func testIDEncodesAsInteger() throws {
        let id = JSONRPCID.int(42)
        let bytes = try encoder.encode(id)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "42")
    }

    func testIDEncodesAsString() throws {
        let id = JSONRPCID.string("abc")
        let bytes = try encoder.encode(id)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "\"abc\"")
    }

    func testIDEncodesAsNull() throws {
        let id = JSONRPCID.null
        let bytes = try encoder.encode(id)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "null")
    }

    func testIDDecodesAllShapes() throws {
        XCTAssertEqual(try decoder.decode(JSONRPCID.self, from: Data("42".utf8)), .int(42))
        XCTAssertEqual(try decoder.decode(JSONRPCID.self, from: Data("\"abc\"".utf8)), .string("abc"))
        XCTAssertEqual(try decoder.decode(JSONRPCID.self, from: Data("null".utf8)), .null)
    }

    // MARK: - Request

    func testRequestRoundTripWithParams() throws {
        let original = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"foo"}}"#
        let req = try decoder.decode(JSONRPCRequest.self, from: Data(original.utf8))
        XCTAssertEqual(req.method, "tools/call")
        XCTAssertEqual(req.id, .int(1))
        XCTAssertNotNil(req.params)
        // Re-encode and ensure semantically equivalent (key order may shift).
        let reEncoded = try encoder.encode(req)
        let reDecoded = try decoder.decode(JSONRPCRequest.self, from: reEncoded)
        XCTAssertEqual(reDecoded.method, "tools/call")
        XCTAssertEqual(reDecoded.id, .int(1))
        XCTAssertEqual(reDecoded.params, req.params)
    }

    func testRequestWithoutParams() throws {
        let original = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let req = try decoder.decode(JSONRPCRequest.self, from: Data(original.utf8))
        XCTAssertEqual(req.method, "tools/list")
        XCTAssertNil(req.params)
    }

    // MARK: - Response

    func testSuccessResponseEncodesResult() throws {
        let resultBytes = Data("{\"ok\":true}".utf8)
        let response = JSONRPCResponse.success(id: .int(7), result: resultBytes)
        let json = try encoder.encode(response)
        let asString = String(data: json, encoding: .utf8)!
        XCTAssertTrue(asString.contains("\"id\":7"))
        XCTAssertTrue(asString.contains("\"result\""))
        XCTAssertFalse(asString.contains("\"error\""))
    }

    func testFailureResponseEncodesError() throws {
        let err = JSONRPCErrorPayload(code: -32601, message: "method not found")
        let response = JSONRPCResponse.failure(id: .int(7), error: err)
        let json = try encoder.encode(response)
        let asString = String(data: json, encoding: .utf8)!
        XCTAssertTrue(asString.contains("\"error\""))
        XCTAssertTrue(asString.contains("method not found"))
        XCTAssertFalse(asString.contains("\"result\""))
    }

    func testResponseDecodesError() throws {
        let payload = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}"#
        let resp = try decoder.decode(JSONRPCResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(resp.error?.code, -32601)
        XCTAssertEqual(resp.error?.message, "nope")
        XCTAssertNil(resp.result)
    }

    // MARK: - JSONValue

    func testJSONValueRoundTrip() throws {
        let value = JSONValue.object([
            "list": .array([.int(1), .string("two"), .null]),
            "flag": .bool(true)
        ])
        let bytes = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: bytes)
        XCTAssertEqual(decoded, value)
    }
}
