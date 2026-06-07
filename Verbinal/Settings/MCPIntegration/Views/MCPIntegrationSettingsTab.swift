// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

/// Settings ▸ MCP. Diagnoses the Claude Desktop / MCP integration end to end
/// (server, sidecar, helper launch) and repairs Claude Desktop's config to
/// point at this app's built-in MCP server (the app launched in MCP mode).
struct MCPIntegrationSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var model: MCPDiagnosticsModel?
    /// Show/hide the AI Guide launchpad tile (OFF by default). Shared key with
    /// `LandingView`, so flipping it here re-renders the tile immediately.
    @AppStorage(AIGuidePreferences.showLandingTileKey) private var showAIGuideTile = false

    private var agents: AgentsService { appState.agentsService }
    private var settings: MCPIntegrationSettingsService { appState.mcpIntegrationSettings }

    var body: some View {
        Form {
            statusSection
            aiGuideSection
            diagnosticsSection
            selfTestSection
            configSection
            claudeCodeSection
            if let err = model?.actionError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if model == nil {
                model = MCPDiagnosticsModel(agents: appState.agentsService, settings: settings)
            }
            model?.runAll()
        }
    }

    private var aiGuideSection: some View {
        Section {
            Toggle("Show AI Guide on the launchpad", isOn: $showAIGuideTile)
        } header: {
            Text("AI Guide")
        } footer: {
            Text("The AI Guide tile on the home screen lets you re-tune the descriptions the MCP server advertises for each tool and author your own read-only instruction tools. Hiding the tile only removes the shortcut — your saved overrides and guide tools stay active.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                // One authoritative status, shared with the AI Agent tab.
                // The compact form points back there for the controls so
                // the two tabs can't drift in wording.
                MCPServerStatusRow(
                    isRunning: agents.isRunning,
                    socketPath: agents.socketPath,
                    lastError: agents.lastError,
                    compact: true
                )
                Button("Re-check") { model?.runAll() }
                    .controlSize(.small)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Claude Desktop and other MCP clients reach Verbinal by launching it in MCP mode (Verbinal mcp). These checks verify each link in that chain and can repair Claude Desktop's config.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            if let checks = model?.checks, !checks.isEmpty {
                ForEach(checks) { check in
                    MCPDiagnosticRow(check: check) { model?.applyFix($0) }
                }
            } else {
                Text("Running checks…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Diagnostics")
        }
    }

    private var selfTestSection: some View {
        Section {
            if let test = model?.selfTest {
                MCPDiagnosticRow(check: test) { model?.applyFix($0) }
            }
            Button {
                Task { await model?.runSelfTest() }
            } label: {
                if model?.isRunningSelfTest == true {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run MCP server check")
                }
            }
            .controlSize(.small)
            .disabled(model?.isRunningSelfTest == true)
        } header: {
            Text("MCP server self-test")
        } footer: {
            Text("Confirms the MCP server is reachable. Your AI client (Claude Desktop/Code) launches Verbinal itself in MCP mode, so the definitive check is restarting your client and confirming the Verbinal tools appear. Requires the server to be running.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var configSection: some View {
        Section {
            Button("Configure Claude Desktop") { model?.configureClaude() }
                .buttonStyle(.borderedProminent)
            HStack {
                Button("Grant Access…") { model?.applyFix(.grantConfigAccess) }
                    .controlSize(.small)
                Button("Update Config") { model?.applyFix(.updateConfig) }
                    .controlSize(.small)
                    .disabled(!settings.hasConfigAccess)
            }
            HStack {
                Button("Copy Snippet") { settings.copyConfigSnippet() }
                    .controlSize(.small)
                Button("Reveal Config") { settings.revealConfigInFinder() }
                    .controlSize(.small)
                Button("Open Claude") { settings.openClaude() }
                    .controlSize(.small)
            }
            if model?.didUpdateConfig == true {
                Label("Config updated — restart Claude Desktop to apply.", systemImage: "arrow.clockwise.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Claude Desktop Configuration")
        } footer: {
            Text("“Configure Claude Desktop” grants one-time access to the Claude config folder, then points the \(MCPIntegrationSettingsService.serverKey) entry at this app, launched in MCP mode. Only that entry is changed; a .bak backup is written first. Restart Claude Desktop after updating.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var claudeCodeSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: settings.isClaudeCodeDetected() ? "checkmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(settings.isClaudeCodeDetected() ? Color.green : Color.secondary)
                    .accessibilityLabel(settings.isClaudeCodeDetected() ? "Claude Code detected" : "Claude Code not detected")
                Text(settings.isClaudeCodeDetected() ? "Claude Code detected" : "Claude Code not detected")
                    .font(.callout)
                Spacer()
            }
            Text(settings.claudeCodeAddCommand())
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Button("Copy Command") { settings.copyClaudeCodeAddCommand() }
                    .controlSize(.small)
                Button("Copy JSON Snippet") { settings.copyClaudeCodeSnippet() }
                    .controlSize(.small)
                Button("Reveal Config") { settings.revealClaudeCodeConfig() }
                    .controlSize(.small)
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("Claude Code stores MCP servers in ~/.claude.json, which also holds auth tokens — so Verbinal doesn't edit it directly. Run the pre-filled `claude mcp add` command in a terminal to register the helper user-wide (the safe, official way), or paste the JSON snippet into the top-level mcpServers. Restart Claude Code afterwards.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
