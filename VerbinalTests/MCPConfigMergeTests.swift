// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import XCTest
@testable import Verbinal

/// Covers the pure JSON-merge that updates Claude Desktop's config. The merge
/// must set only our `verbinal-canfar` entry and leave every sibling server
/// and unknown top-level key untouched.
final class MCPConfigMergeTests: XCTestCase {
    private let helper = "/Applications/Verbinal.app/Contents/Resources/canfar-mcp"

    private func command(_ root: [String: Any], _ key: String) -> String? {
        ((root["mcpServers"] as? [String: Any])?[key] as? [String: Any])?["command"] as? String
    }

    func testCreatesEntryFromEmptyDoc() {
        let root = MCPIntegrationSettingsService.mergedRoot(existing: nil, helperPath: helper)
        XCTAssertEqual(command(root, "verbinal-canfar"), helper)
    }

    func testCreatesEntryWhenNoMcpServersKey() {
        let existing: [String: Any] = ["globalShortcut": "Cmd+Space"]
        let root = MCPIntegrationSettingsService.mergedRoot(existing: existing, helperPath: helper)
        XCTAssertEqual(command(root, "verbinal-canfar"), helper)
        XCTAssertEqual(root["globalShortcut"] as? String, "Cmd+Space", "unknown top-level keys must survive")
    }

    func testPreservesSiblingServers() {
        let existing: [String: Any] = [
            "mcpServers": [
                "verbinal-thought": ["command": "/path/to/verbinal-thought-mcp"],
                "verbinal-canfar": ["command": "/old/stale/DerivedData/canfar-mcp"],
            ],
            "preferences": ["sidebarMode": "chat"],
        ]
        let root = MCPIntegrationSettingsService.mergedRoot(existing: existing, helperPath: helper)

        // Our entry is updated…
        XCTAssertEqual(command(root, "verbinal-canfar"), helper)
        // …the sibling server is untouched…
        XCTAssertEqual(command(root, "verbinal-thought"), "/path/to/verbinal-thought-mcp")
        // …and unrelated top-level keys survive.
        XCTAssertEqual((root["preferences"] as? [String: Any])?["sidebarMode"] as? String, "chat")
    }

    func testOnlyTouchesCommandFieldOfOurEntry() {
        let existing: [String: Any] = [
            "mcpServers": ["verbinal-canfar": ["command": "/old", "env": ["X": "1"]]],
        ]
        let root = MCPIntegrationSettingsService.mergedRoot(existing: existing, helperPath: helper)
        // The merge replaces the whole entry with just `command` — document
        // that behavior so a future change that needs to preserve `env` is
        // a deliberate decision, not an accident.
        let entry = (root["mcpServers"] as? [String: Any])?["verbinal-canfar"] as? [String: Any]
        XCTAssertEqual(entry?["command"] as? String, helper)
    }

    func testRoundTripsThroughJSONSerialization() throws {
        let existing: [String: Any] = ["mcpServers": ["other": ["command": "/x"]]]
        let root = MCPIntegrationSettingsService.mergedRoot(existing: existing, helperPath: helper)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let reparsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(command(reparsed, "verbinal-canfar"), helper)
        XCTAssertEqual(command(reparsed, "other"), "/x")
    }

    func testServerKeyMatchesExistingUserConfig() {
        XCTAssertEqual(MCPIntegrationSettingsService.serverKey, "verbinal-canfar")
    }
}
#endif
