// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
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
}
