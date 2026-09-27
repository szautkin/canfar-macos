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

    private let strictSchema = #"""
    {"type":"object","properties":{"downloaded_observation_id":{"type":"string"},"proposalId":{"type":"string"}},"additionalProperties":false}
    """#

    private func check(_ arguments: String) -> ToolInputSchema.ArgumentCheck {
        ToolInputSchema.check(schema: parse(strictSchema), arguments: Data(arguments.utf8))
    }

    private func object(_ result: ToolInputSchema.ArgumentCheck) -> [String: JSONValue]? {
        guard case .accepted(let data) = result else { return nil }
        return ToolInputSchema.argumentObject(in: data)
    }

    func testDeclaredSpellingPassesUnchanged() {
        let raw = #"{"downloaded_observation_id":"x"}"#
        XCTAssertEqual(check(raw), .accepted(Data(raw.utf8)))
    }

    /// Tools decode with a plain JSONDecoder, so an alias must reach them
    /// under the declared name — passing it through would drop an optional
    /// argument silently.
    func testAliasIsRenamedToTheDeclaredSpelling() {
        XCTAssertEqual(object(check(#"{"downloadedObservationId":"x"}"#)),
                       ["downloaded_observation_id": .string("x")])
        XCTAssertEqual(object(check(#"{"proposal_id":"u"}"#)),
                       ["proposalId": .string("u")])
    }

    func testUnknownArgumentIsRefusedByName() {
        guard case .refused(let why) = check(#"{"downloaded_observation_id":"x","extra":1}"#) else {
            return XCTFail("expected refusal")
        }
        XCTAssertTrue(why.contains("extra"), why)
        XCTAssertTrue(why.contains("downloaded_observation_id"), why)
    }

    func testTwoSpellingsOfOneArgumentAreRefused() {
        guard case .refused(let why) = check(#"{"proposalId":"a","proposal_id":"b"}"#) else {
            return XCTFail("expected refusal")
        }
        XCTAssertTrue(why.contains("proposalId") && why.contains("proposal_id"), why)
    }

    func testNullAndEmptyArgumentsAreAnEmptyObject() {
        XCTAssertEqual(check("null"), .accepted(Data("null".utf8)))
        XCTAssertEqual(check(""), .accepted(Data()))
    }

    func testCamelCaseLeavesNamesWithoutUnderscoresAlone() {
        XCTAssertEqual(ToolInputSchema.camelCase("proposalId"), "proposalId")
        XCTAssertEqual(ToolInputSchema.camelCase("foo_bar_baz"), "fooBarBaz")
        XCTAssertEqual(ToolInputSchema.snakeCase("proposalId"), "proposal_id")
    }
}
