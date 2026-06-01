// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// Ticket 001: `JSONReadTool.invoke` synthesises `EmptyArgs` for no-arg tools
/// when arguments are null/empty/`{}` — verified without the former
/// `as! Args` force-cast — and does NOT take that special case for tools
/// with a real `Args` type.
final class JSONReadToolEmptyArgsTests: XCTestCase {

    private struct NoArgsTool: JSONReadTool {
        struct Out: Encodable & Sendable { let ok: Bool }
        let definition = AIToolDefinition.withStaticSchema(
            name: "noargs", description: "no-arg tool",
            schema: #"{"type":"object","properties":{}}"#
        )
        func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Out { Out(ok: true) }
    }

    private struct TypedTool: JSONReadTool {
        struct Args: Decodable & Sendable { let x: Int }
        struct Out: Codable & Sendable { let x: Int }
        let definition = AIToolDefinition.withStaticSchema(
            name: "typed", description: "needs x",
            schema: #"{"type":"object","properties":{"x":{"type":"integer"}}}"#
        )
        func handle(_ args: Args, context: AIToolContext) async throws -> Out { Out(x: args.x) }
    }

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 8))
    }

    private func assertData(_ result: ToolResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .data = result else { return XCTFail("expected .data, got \(result)", file: file, line: line) }
    }
    private func assertFailed(_ result: ToolResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed = result else { return XCTFail("expected .failed, got \(result)", file: file, line: line) }
    }

    func testEmptyArgsToolAcceptsEmptyNullAndBraces() async {
        let tool = NoArgsTool()
        assertData(await tool.invoke(arguments: Data(), context: ctx()))
        assertData(await tool.invoke(arguments: Data("null".utf8), context: ctx()))
        assertData(await tool.invoke(arguments: Data("{}".utf8), context: ctx()))
    }

    func testTypedToolDecodesRealArgs() async {
        let result = await TypedTool().invoke(arguments: Data(#"{"x":5}"#.utf8), context: ctx())
        guard case .data(let bytes) = result else { return XCTFail("expected .data, got \(result)") }
        let out = try? JSONDecoder().decode(TypedTool.Out.self, from: bytes)
        XCTAssertEqual(out?.x, 5)
    }

    func testTypedToolDoesNotTakeEmptyArgsShortcut() async {
        // Args != EmptyArgs, so empty input must NOT synthesise EmptyArgs;
        // it should fail to decode the required `x`.
        assertFailed(await TypedTool().invoke(arguments: Data(), context: ctx()))
    }
}
