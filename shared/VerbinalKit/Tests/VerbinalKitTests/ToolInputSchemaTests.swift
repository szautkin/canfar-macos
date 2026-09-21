// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit
@testable import MCPCore

final class ToolInputSchemaTests: XCTestCase {

    private func parse(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testRejectsNonObjectSchema() {
        let problems = ToolInputSchema.problems(in: parse(#""string""#))
        XCTAssertEqual(problems, ["schema must be a JSON object"])
    }

    func testRejectsNonObjectType() {
        let problems = ToolInputSchema.problems(in: parse(#"{"type":"array","items":{}}"#))
        XCTAssertTrue(problems.contains { $0.contains("type must be") }, "\(problems)")
    }

    func testRequiredMustBeDeclaredInProperties() {
        let problems = ToolInputSchema.problems(in: parse(#"""
        {"type":"object","properties":{"a":{"type":"string"}},"required":["b"]}
        """#))
        XCTAssertTrue(problems.contains { $0.contains("required \"b\"") }, "\(problems)")
    }

    func testValidObjectSchemaHasNoProblems() {
        let problems = ToolInputSchema.problems(in: parse(#"""
        {"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
        """#))
        XCTAssertEqual(problems, [])
    }

    func testUndeclaredArgumentsHonoursSnakeCamelAlias() {
        let schema = parse(#"""
        {"type":"object","properties":{"downloaded_observation_id":{"type":"string"}},"additionalProperties":false}
        """#)
        XCTAssertEqual(
            ToolInputSchema.undeclaredArguments(
                schema: schema,
                arguments: Data(#"{"downloadedObservationId":"x"}"#.utf8)
            ),
            []
        )
        XCTAssertEqual(
            ToolInputSchema.undeclaredArguments(
                schema: schema,
                arguments: Data(#"{"downloaded_observation_id":"x","extra":1}"#.utf8)
            ),
            ["extra"]
        )
    }
}
