// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import Foundation
import VerbinalKit
@testable import Verbinal

/// Parity guardrails: the live tool registry and the AI Guide catalog
/// must agree in BOTH directions. A tool without a category silently
/// lands in "Other" on the AI Guide screen; a catalog entry without a
/// tool is dead weight that misleads the screen and this repo's parity
/// matrix (docs/agent-ui-parity.md).
final class AgentToolCatalogParityTests: XCTestCase {

    @MainActor
    func testEveryRegisteredToolHasACatalogCategoryAndUniqueName() {
        let tools = AppState().makeAgentTools()
        XCTAssertGreaterThan(tools.count, 100, "registry unexpectedly small — wiring broken?")

        var seen = Set<String>()
        var duplicates: [String] = []
        var uncategorized: [String] = []
        for tool in tools {
            if !seen.insert(tool.name).inserted { duplicates.append(tool.name) }
            if AIGuideCatalog.categoryID(forTool: tool.name) == AIGuideCatalog.other.id {
                uncategorized.append(tool.name)
            }
        }
        XCTAssertTrue(duplicates.isEmpty, "duplicate tool names registered: \(duplicates)")
        XCTAssertTrue(uncategorized.isEmpty,
                      "tools missing an AIGuideCatalog category (add them): \(uncategorized)")
    }

    @MainActor
    func testEveryCatalogEntryMapsToARegisteredTool() {
        let registered = Set(AppState().makeAgentTools().map(\.name))
        let stale = AIGuideCatalog.allMappedToolNames.filter { !registered.contains($0) }
        XCTAssertTrue(stale.isEmpty,
                      "catalog entries with no registered tool (remove or wire them): \(stale)")
    }

    func testCatalogCategoriesAreWellFormed() {
        let ids = AIGuideCatalog.categories.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate category ids")
        // Every mapped tool must point at a declared category.
        let known = Set(ids)
        let dangling = AIGuideCatalog.allMappedToolNames.filter {
            !known.contains(AIGuideCatalog.categoryID(forTool: $0))
        }
        XCTAssertTrue(dangling.isEmpty, "tools mapped to unknown category ids: \(dangling)")
    }

    @MainActor
    func testEveryAdvertisedInputSchemaIsAnObject() {
        let tools = AppState().makeAgentTools()
        var broken: [String] = []
        for tool in tools {
            let problems = ToolInputSchema.problems(in: tool.definition.inputSchema)
            if !problems.isEmpty {
                broken.append("\(tool.name): \(problems.joined(separator: "; "))")
            }
        }
        XCTAssertTrue(broken.isEmpty, "malformed inputSchema:\n\(broken.joined(separator: "\n"))")
    }

    @MainActor
    func testDescribeAppBacktickToolNamesAreRegistered() {
        let registered = Set(AppState().makeAgentTools().map(\.name))
        XCTAssertTrue(registered.contains("delete_saved_query"),
                      "delete_saved_query must stay on the live surface (describe_app advertises it)")
        let documented = Self.snakeCaseBacktickNames(in: DescribeAppTool.brief)
        XCTAssertTrue(documented.contains("delete_saved_query"))
        let unknown = documented.subtracting(registered)
        XCTAssertTrue(
            unknown.isEmpty,
            "describe_app names tools that are not registered: \(unknown.sorted())")
    }

    /// Snake_case identifiers that appear inside backticks in the brief.
    /// Stops at the first non-name character so `get_proposal_state(id)`
    /// and `get_current_view.mode` still yield the tool name.
    private static func snakeCaseBacktickNames(in text: String) -> Set<String> {
        let pattern = "`([a-z][a-z0-9]*(?:_[a-z0-9]+)+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return Set(matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1))
        })
    }
}
