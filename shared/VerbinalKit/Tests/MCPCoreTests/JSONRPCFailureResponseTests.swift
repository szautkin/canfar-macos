// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

/// Ticket 008: the canfar-mcp helper's drain-and-fail path builds a
/// well-formed JSON-RPC error response so a down app never leaves the client
/// in silence. The helper has no test target, so this pins the response shape
/// (the testable seam) here in MCPCore.
final class JSONRPCFailureResponseTests: XCTestCase {

    func testFailureResponseRoundTripsWithIntID() throws {
        let payload = JSONRPCErrorPayload(code: JSONRPCErrorCode.serviceUnavailable,
                                          message: "Verbinal app is not running.")
        let response = JSONRPCResponse.failure(id: .int(7), error: payload)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)

        XCTAssertEqual(decoded.id, .int(7))
        XCTAssertEqual(decoded.error?.code, JSONRPCErrorCode.serviceUnavailable)
        XCTAssertEqual(decoded.error?.message, "Verbinal app is not running.")
        XCTAssertNil(decoded.result, "a failure must not also carry a result")
    }

    func testFailureResponseRoundTripsWithStringID() throws {
        let response = JSONRPCResponse.failure(
            id: .string("abc"),
            error: JSONRPCErrorPayload(code: JSONRPCErrorCode.serviceUnavailable, message: "down")
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        XCTAssertEqual(decoded.id, .string("abc"))
        XCTAssertEqual(decoded.error?.code, JSONRPCErrorCode.serviceUnavailable)
    }
}
