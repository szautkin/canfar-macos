// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Plan 52 D: each client's settings and the prompt, built in one place —
/// and the same as AGENTS.md shows, so the app and the guide never drift.
final class AssistantRecipesTests: XCTestCase {
    private let installed = "/Applications/Verbinal.app/Contents/MacOS/Verbinal"

    private func repositoryFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testAgentsMDShowsWhatTheAppShows() throws {
        let guide = try repositoryFile("AGENTS.md")
        for recipe in AssistantRecipes.all(executable: installed) {
            XCTAssertTrue(guide.contains(recipe.text), "AGENTS.md lacks \(recipe.client.name)'s:\n\(recipe.text)")
            if let file = recipe.file {
                XCTAssertTrue(guide.contains(file), "AGENTS.md lacks \(recipe.client.name)'s file \(file)")
            }
        }
        let manual = try repositoryFile("docs/manual/en/12-ai-assistant.md")
        XCTAssertTrue(manual.contains(AssistantRecipes.claudeCodeCommand(installed)))
    }

    func testEveryJSONEntryParsesAndNamesTheServer() throws {
        let odd = "/Users/me/Apps/My \"Odd\" Verbinal.app/Contents/MacOS/Verbinal"
        for client in AssistantRecipes.Client.allCases where client != .claudeCode && client != .codex {
            let text = AssistantRecipes.recipe(for: client, executable: odd).text
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
            let servers = try XCTUnwrap((root["mcpServers"] ?? root["servers"]) as? [String: Any])
            let entry = try XCTUnwrap(servers["verbinal-canfar"] as? [String: Any])
            XCTAssertEqual(entry["command"] as? String, odd)
            XCTAssertEqual(entry["args"] as? [String], ["mcp"])
        }
        let claudeCode = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AssistantRecipes.claudeCodeEntry(odd).utf8)) as? [String: Any])
        XCTAssertEqual(((claudeCode["mcpServers"] as? [String: Any])?["verbinal-canfar"] as? [String: Any])?["type"] as? String, "stdio")
    }

    func testCodexAndTheShellQuoteAPathWithSpacesAndQuotes() {
        let odd = "/Apps/My \"App\".app/Contents/MacOS/Verbinal"
        XCTAssertEqual(AssistantRecipes.recipe(for: .codex, executable: odd).text, #"""
            [mcp_servers.verbinal-canfar]
            command = "/Apps/My \"App\".app/Contents/MacOS/Verbinal"
            args = ["mcp"]
            """#)
        XCTAssertEqual(AssistantRecipes.claudeCodeCommand("/Apps/It's/Verbinal"),
                       #"claude mcp add --transport stdio --scope user verbinal-canfar -- '/Apps/It'\''s/Verbinal' 'mcp'"#)
    }

    func testThePromptSaysWhatAnAssistantNeeds() {
        let prompt = AssistantRecipes.prompt(executable: installed)
        for needed in [installed, "verbinal-canfar", #"["mcp"]"#, "describe_app", "start_session", AssistantRecipes.agentsGuide] {
            XCTAssertTrue(prompt.contains(needed), "the prompt lacks \(needed)")
        }
    }
}
