// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import Foundation
import AppKit
import Observation

/// Errors surfaced by the Claude-config grant/merge flow.
enum MCPConfigError: LocalizedError, Equatable {
    case cancelled                     // user dismissed the open panel — not an error to show
    case noAccess                      // no folder bookmark granted
    case helperNotFound(String)
    case helperNotExecutable(String)
    case bookmarkStale                 // bookmark could not be resolved — re-grant needed
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:                 "Cancelled."
        case .noAccess:                  "Grant access to the Claude config folder first."
        case .helperNotFound(let p):     "The Verbinal MCP server binary was not found at \(p)."
        case .helperNotExecutable(let p): "The Verbinal MCP server binary at \(p) is not executable."
        case .bookmarkStale:             "Access to the Claude config folder expired — grant access again."
        case .readFailed(let m):         "Could not read the Claude config: \(m)"
        case .writeFailed(let m):        "Could not update the Claude config: \(m)"
        }
    }
}

/// Owns persistence for the MCP integration settings tab: the security-scoped
/// bookmark to Claude Desktop's config folder, plus the read/merge/write of
/// `claude_desktop_config.json` and the helper-path / Claude-app lookups the
/// diagnostics need. `@Observable @MainActor`, mirroring
/// `ImageDiscoverySettingsService`.
@Observable @MainActor
final class MCPIntegrationSettingsService {
    /// The key under `mcpServers` we own. Matches the existing user config.
    /// `nonisolated` so the pure `mergedRoot` helper (and tests) can read it.
    nonisolated static let serverKey = "verbinal-canfar"
    static let configFileName = "claude_desktop_config.json"
    /// Claude Desktop's bundle id (current first, legacy fallback).
    static let claudeBundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.Claude"]

    private static let bookmarkKey = "com.codebg.Verbinal.mcpIntegration.claudeConfigFolderBookmark"

    private let defaults: UserDefaults
    private(set) var settings: MCPIntegrationSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = MCPIntegrationSettings(
            claudeConfigBookmark: defaults.data(forKey: Self.bookmarkKey)
        )
    }

    var hasConfigAccess: Bool { settings.hasConfigAccess }

    // MARK: - Helper binary

    /// The command Claude (and other MCP clients) should launch to reach
    /// Verbinal: this app's OWN main binary, invoked with the `mcp` argument
    /// (`serverLaunchArguments`). Unlike the old bundled bare `canfar-mcp`
    /// helper, the main app binary carries the bundle's embedded provisioning
    /// profile and a full (non-`inherit`) sandbox, so it can reach the App
    /// Group socket under Mac App Store distribution signing — a bare embedded
    /// tool traps at launch instead. See `MCPStdioBridge` for the rationale.
    static var helperURL: URL {
        Bundle.main.executableURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Verbinal")
    }

    /// Arguments that switch the app binary into headless MCP-bridge mode.
    nonisolated static let serverLaunchArguments = ["mcp"]

    func resolveHelperPath() throws -> String {
        let url = Self.helperURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPConfigError.helperNotFound(url.path)
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MCPConfigError.helperNotExecutable(url.path)
        }
        return url.path
    }

    // MARK: - Claude Desktop app

    func claudeAppURL() -> URL? {
        for id in Self.claudeBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    func openClaude() {
        if let app = claudeAppURL() {
            NSWorkspace.shared.open(app)
        } else if let download = URL(string: "https://claude.ai/download") {
            NSWorkspace.shared.open(download)
        }
    }

    // MARK: - Config locations

    /// The user's REAL home directory. In a sandboxed (App Store) build
    /// `FileManager.homeDirectoryForCurrentUser` / `NSHomeDirectory()` return the
    /// app's CONTAINER (`~/Library/Containers/<id>/Data`), NOT `~`. Claude's
    /// config lives in the real `~`, so read the passwd entry to get it.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The conventional Claude Desktop config folder —
    /// `~/Library/Application Support/Claude/` (holds `claude_desktop_config.json`,
    /// where MCP servers are defined). Used to pre-target the grant-access panel
    /// and to reveal-in-Finder when no bookmark exists.
    static var defaultConfigFolder: URL {
        realHomeDirectory
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    private func configFileURL(inFolder folder: URL) -> URL {
        folder.appendingPathComponent(Self.configFileName)
    }

    // MARK: - Grant access (folder-scoped bookmark)

    func grantConfigAccess() throws {
        let panel = NSOpenPanel()
        panel.message = "Select Claude Desktop's “Claude” configuration folder so Verbinal can register its helper automatically."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Pre-target the REAL ~/Library/Application Support/Claude, unconditionally:
        // a sandboxed app can't stat that external path before the grant, so a
        // fileExists() check would skip the pre-target and strand the user at their
        // container. The powerbox open-panel can navigate there regardless.
        panel.directoryURL = Self.defaultConfigFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { throw MCPConfigError.cancelled }
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        setBookmark(bookmark)
    }

    private func setBookmark(_ data: Data) {
        settings.claudeConfigBookmark = data
        defaults.set(data, forKey: Self.bookmarkKey)
    }

    /// Resolve the folder bookmark and run `body` with the security scope
    /// active. Refreshes a stale bookmark. Throws `MCPConfigError` on failure.
    private func withConfigFolder<T>(_ body: (_ folder: URL) throws -> T) throws -> T {
        guard let bookmark = settings.claudeConfigBookmark else { throw MCPConfigError.noAccess }
        var stale = false
        guard let folder = try? URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope],
            relativeTo: nil, bookmarkDataIsStale: &stale
        ) else { throw MCPConfigError.bookmarkStale }
        let started = folder.startAccessingSecurityScopedResource()
        defer { if started { folder.stopAccessingSecurityScopedResource() } }
        let result = try body(folder)
        if stale, let fresh = try? folder.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) { setBookmark(fresh) }
        return result
    }

    // MARK: - Probe (diagnostics check #9)

    func probeConfig() -> ClaudeConfigProbe {
        guard settings.hasConfigAccess else { return .noAccess }
        do {
            return try withConfigFolder { folder in
                let url = configFileURL(inFolder: folder)
                guard FileManager.default.fileExists(atPath: url.path) else { return .fileMissing }
                guard let data = try? Data(contentsOf: url) else { return .unreadable("read failed") }
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return .unreadable("not valid JSON")
                }
                let servers = root["mcpServers"] as? [String: Any]
                guard let entry = servers?[Self.serverKey] as? [String: Any],
                      let command = entry["command"] as? String else { return .noEntry }
                return .entry(command: command)
            }
        } catch let error as MCPConfigError {
            return error == .bookmarkStale ? .unreadable("access expired") : .unreadable("\(error.localizedDescription)")
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    // MARK: - Merge (the auto-repair)

    /// Pure merge: return `existing` (or an empty doc) with
    /// `mcpServers[serverKey].command` set to `helperPath`, preserving every
    /// other server entry and top-level key untouched. Any non-`command`
    /// fields already on our own entry (e.g. user-set `env` / `env_file`) are
    /// retained — only `command` is overwritten. Extracted so it can be
    /// unit-tested without any file/bookmark plumbing.
    nonisolated static func mergedRoot(existing: [String: Any]?, helperPath: String) -> [String: Any] {
        var root = existing ?? [:]
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        var entry = (servers[serverKey] as? [String: Any]) ?? [:]
        entry["command"] = helperPath
        // The app binary IS the server; the `mcp` argument switches it into
        // headless bridge mode. Overwrite args (the command itself changed),
        // preserving any other user-set fields (e.g. env) on the entry.
        entry["args"] = serverLaunchArguments
        servers[serverKey] = entry
        root["mcpServers"] = servers
        return root
    }

    /// Set `mcpServers["verbinal-canfar"].command` to this app's own helper
    /// path, preserving every other key/server. Backs up to `.bak`, writes
    /// atomically via temp + `replaceItemAt`.
    func mergeVerbinalEntry() throws {
        let helperPath = try resolveHelperPath()
        try withConfigFolder { folder in
            let url = configFileURL(inFolder: folder)

            var existing: [String: Any]?
            var originalData: Data?
            if FileManager.default.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url) else {
                    throw MCPConfigError.readFailed(Self.configFileName)
                }
                if !data.isEmpty {
                    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        throw MCPConfigError.readFailed("existing config is not a valid JSON object")
                    }
                    existing = obj
                    originalData = data
                }
            }

            let root = Self.mergedRoot(existing: existing, helperPath: helperPath)

            guard let out = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
            ) else { throw MCPConfigError.writeFailed("could not serialize config") }

            // Back up the original only after the new content serialized OK —
            // a serialization failure must never leave an orphaned .bak.
            if let originalData {
                try? originalData.write(to: url.appendingPathExtension("bak"), options: .atomic)
            }

            do {
                let tmp = folder.appendingPathComponent("\(Self.configFileName).verbinal-tmp")
                // Clear any leftover temp from a previously interrupted write.
                if FileManager.default.fileExists(atPath: tmp.path) {
                    try? FileManager.default.removeItem(at: tmp)
                }
                try out.write(to: tmp, options: .atomic)
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: url)
                }
            } catch {
                throw MCPConfigError.writeFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Manual fallbacks

    /// The JSON the user would paste manually, with the correct helper path.
    func configSnippet() -> String {
        let path = (try? resolveHelperPath()) ?? Self.helperURL.path
        let dict: [String: Any] = ["mcpServers": [Self.serverKey: ["command": path, "args": Self.serverLaunchArguments]]]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func copyConfigSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configSnippet(), forType: .string)
    }

    func revealConfigInFinder() {
        if settings.hasConfigAccess,
           let target = try? withConfigFolder({ folder -> URL in
               let file = configFileURL(inFolder: folder)
               return FileManager.default.fileExists(atPath: file.path) ? file : folder
           }) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
            return
        }
        let folder = Self.defaultConfigFolder
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    func revealHelperInFinder() {
        let url = Self.helperURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Claude Code (CLI client)

    /// Claude Code stores user-scoped MCP servers in `~/.claude.json` under a
    /// top-level `mcpServers` object. That file ALSO holds OAuth tokens +
    /// per-project state, so — unlike Claude Desktop — we never auto-overwrite
    /// it. Instead we hand the user the official, safe `claude mcp add` command
    /// (pre-filled with this app's helper path), which merges the entry
    /// without disturbing anything else. A JSON snippet is offered as a
    /// hand-edit fallback.
    static let claudeCodeConfigFileName = ".claude.json"

    static var claudeCodeConfigURL: URL {
        realHomeDirectory
            .appendingPathComponent(claudeCodeConfigFileName)
    }
    static var claudeCodeConfigDirURL: URL {
        realHomeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Best-effort presence hint. The sandbox can hide these even when present,
    /// so the configure command is always offered regardless of this result.
    func isClaudeCodeDetected() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Self.claudeCodeConfigURL.path)
            || fm.fileExists(atPath: Self.claudeCodeConfigDirURL.path)
    }

    /// Wrap an absolute path as a single-quoted POSIX shell argument — handles
    /// spaces and suppresses `$`/backtick/quote expansion that double quotes
    /// would allow. Embedded single quotes use the standard `'\''` idiom.
    nonisolated static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The exact `claude mcp add` command, pre-populated with this app's helper
    /// path — the safe, official way to register a user-scoped stdio server.
    func claudeCodeAddCommand() -> String {
        let path = (try? resolveHelperPath()) ?? Self.helperURL.path
        let args = Self.serverLaunchArguments.map(Self.shellSingleQuoted).joined(separator: " ")
        return "claude mcp add --transport stdio --scope user \(Self.serverKey) -- \(Self.shellSingleQuoted(path)) \(args)"
    }

    /// The JSON to merge into `~/.claude.json`'s top-level `mcpServers` for
    /// users who prefer hand-editing. Includes `type: "stdio"` (Claude Code's
    /// stdio entry shape).
    func claudeCodeConfigSnippet() -> String {
        let path = (try? resolveHelperPath()) ?? Self.helperURL.path
        let dict: [String: Any] = ["mcpServers": [Self.serverKey: ["type": "stdio", "command": path, "args": Self.serverLaunchArguments]]]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func copyClaudeCodeAddCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(claudeCodeAddCommand(), forType: .string)
    }

    func copyClaudeCodeSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(claudeCodeConfigSnippet(), forType: .string)
    }

    func revealClaudeCodeConfig() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.claudeCodeConfigURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Self.claudeCodeConfigURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([Self.realHomeDirectory])
        }
    }
}
#endif
