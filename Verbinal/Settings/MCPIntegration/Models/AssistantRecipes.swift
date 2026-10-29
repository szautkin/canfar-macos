// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// How each assistant's client adds Verbinal's server, and a prompt that
/// asks an assistant to add it itself (plan 52 D). One place builds them
/// from this Mac's executable — for Settings, the setup and Connected
/// Assistants — and a test checks AGENTS.md shows the same, so none drift.
enum AssistantRecipes {
    /// The name every client registers the server under.
    static let serverName = "verbinal-canfar"
    /// What turns the app's executable into the server.
    static let arguments = ["mcp"]
    /// Every client's settings, written for an assistant to read.
    static let agentsGuide = "https://github.com/szautkin/canfar-macos/blob/main/AGENTS.md"

    enum Client: String, CaseIterable, Identifiable, Sendable {
        case claudeDesktop, claudeCode, codex, cursor, geminiCLI, windsurf, vsCode
        var id: String { rawValue }

        var name: String {
            switch self {
            case .claudeDesktop: "Claude Desktop"
            case .claudeCode: "Claude Code"
            case .codex: "OpenAI Codex"
            case .cursor: "Cursor"
            case .geminiCLI: "Gemini CLI"
            case .windsurf: "Windsurf"
            case .vsCode: "VS Code (GitHub Copilot)"
            }
        }
    }

    /// One client's way: a file to add `text` to, or, without one, a command to run.
    struct Recipe: Identifiable, Equatable, Sendable {
        let client: Client
        let file: String?
        let text: String
        var id: String { client.id }
    }

    static func all(executable: String) -> [Recipe] {
        Client.allCases.map { recipe(for: $0, executable: executable) }
    }

    static func recipe(for client: Client, executable: String) -> Recipe {
        switch client {
        case .claudeDesktop:
            Recipe(client: client, file: "~/Library/Application Support/Claude/claude_desktop_config.json",
                   text: entry(in: "mcpServers", executable))
        case .claudeCode:
            Recipe(client: client, file: nil, text: claudeCodeCommand(executable))
        case .codex:
            Recipe(client: client, file: "~/.codex/config.toml", text: """
                [mcp_servers.\(serverName)]
                command = \(quoted(executable))
                args = \(argumentList)
                """)
        case .cursor:
            Recipe(client: client, file: "~/.cursor/mcp.json", text: entry(in: "mcpServers", executable))
        case .geminiCLI:
            Recipe(client: client, file: "~/.gemini/settings.json", text: entry(in: "mcpServers", executable))
        case .windsurf:
            Recipe(client: client, file: "~/.codeium/windsurf/mcp_config.json", text: entry(in: "mcpServers", executable))
        case .vsCode:
            Recipe(client: client, file: "mcp.json", text: entry(in: "servers", typed: true, executable))
        }
    }

    /// The official way to add a user-wide server to Claude Code.
    static func claudeCodeCommand(_ executable: String) -> String {
        let args = arguments.map(shellSingleQuoted).joined(separator: " ")
        return "claude mcp add --transport stdio --scope user \(serverName) -- \(shellSingleQuoted(executable)) \(args)"
    }

    /// Claude Code's entry in `~/.claude.json`, for whoever edits it by hand.
    static func claudeCodeEntry(_ executable: String) -> String {
        entry(in: "mcpServers", typed: true, executable)
    }

    /// What a person gives an assistant so it connects itself.
    static func prompt(executable: String) -> String {
        String(localized: "Connect yourself to Verbinal, the CADC/CANFAR app on this Mac. It is a local stdio MCP server: name `\(serverName)`, command `\(executable)`, arguments `\(argumentList)`; no port, URL or key. Add it to your MCP configuration without removing the servers already there, then reload so it appears. Call `describe_app`, then `start_session` saying who you are and why; I approve the session in Verbinal. Exact settings for each client: \(agentsGuide)")
    }

    /// An absolute path as one POSIX shell word: spaces kept, and no `$`,
    /// backtick or quote expansion. An embedded single quote is `'\''`.
    static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Shapes

    /// `{ "<container>": { "verbinal-canfar": { … } } }` on one line, as AGENTS.md shows it.
    private static func entry(in container: String, typed: Bool = false, _ executable: String) -> String {
        let type = typed ? #""type": "stdio", "# : ""
        return #"{ "\#(container)": { "\#(serverName)": { \#(type)"command": \#(quoted(executable)), "args": \#(argumentList) } } }"#
    }

    /// `["mcp"]`, in JSON and TOML alike.
    private static var argumentList: String { "[" + arguments.map(quoted).joined(separator: ", ") + "]" }

    /// A string as JSON writes it, which TOML reads the same.
    private static func quoted(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(s)\""
    }
}
