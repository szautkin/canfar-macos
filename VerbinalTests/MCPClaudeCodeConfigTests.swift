// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import XCTest
@testable import Verbinal

/// Pins the Claude Code (CLI client) configure helpers: the pre-filled
/// `claude mcp add` command and the `~/.claude.json` JSON snippet. Their
/// exact shape is the contract a user copies into a terminal / config,
/// so a regression here silently breaks the "grant access" UX.
final class MCPClaudeCodeConfigTests: XCTestCase {

    @MainActor
    private func service() -> MCPIntegrationSettingsService {
        MCPIntegrationSettingsService(defaults: UserDefaults(suiteName: "test.mcpcc.\(UUID().uuidString)")!)
    }

    @MainActor
    func testAddCommandShape() {
        let cmd = service().claudeCodeAddCommand()
        XCTAssertTrue(cmd.hasPrefix("claude mcp add"), cmd)
        XCTAssertTrue(cmd.contains("--transport stdio"), cmd)
        XCTAssertTrue(cmd.contains("--scope user"), cmd)
        XCTAssertTrue(cmd.contains(MCPIntegrationSettingsService.serverKey), cmd)
        // The `--` separator must precede the command path so flags don't
        // swallow it.
        XCTAssertTrue(cmd.contains(" -- "), cmd)
    }

    @MainActor
    func testSnippetIsValidStdioEntry() throws {
        let snippet = service().claudeCodeConfigSnippet()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(obj["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers[MCPIntegrationSettingsService.serverKey] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "stdio")
        XCTAssertFalse((entry["command"] as? String ?? "").isEmpty)
    }

    @MainActor
    func testConfigURLsAreUnderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(MCPIntegrationSettingsService.claudeCodeConfigURL.lastPathComponent, ".claude.json")
        XCTAssertTrue(MCPIntegrationSettingsService.claudeCodeConfigURL.path.hasPrefix(home))
    }

    func testShellSingleQuotedEscapesPaths() {
        // A path with a space stays a single argument…
        XCTAssertEqual(MCPIntegrationSettingsService.shellSingleQuoted("/Apps/My App/canfar-mcp"),
                       "'/Apps/My App/canfar-mcp'")
        // …and an embedded single quote uses the POSIX '\'' idiom.
        XCTAssertEqual(MCPIntegrationSettingsService.shellSingleQuoted("a'b"), "'a'\\''b'")
    }
}
#endif
