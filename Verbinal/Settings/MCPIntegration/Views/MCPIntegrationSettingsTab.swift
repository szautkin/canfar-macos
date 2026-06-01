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
/// point at this app's bundled `canfar-mcp` helper.
struct MCPIntegrationSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var model: MCPDiagnosticsModel?

    private var agents: AgentsService { appState.agentsService }
    private var settings: MCPIntegrationSettingsService { appState.mcpIntegrationSettings }

    var body: some View {
        Form {
            statusSection
            diagnosticsSection
            selfTestSection
            configSection
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

    private var statusSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: agents.isRunning ? "checkmark.circle.fill" : "moon.zzz.fill")
                    .foregroundStyle(agents.isRunning ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agents.isRunning ? "MCP server listening" : "MCP server stopped")
                        .font(.callout)
                    if let path = agents.socketPath {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("Re-check") { model?.runAll() }
                    .controlSize(.small)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Claude Desktop and other MCP clients reach Verbinal through the bundled canfar-mcp helper. These checks verify each link in that chain and can repair Claude Desktop's config.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                    Text("Run helper self-test")
                }
            }
            .controlSize(.small)
            .disabled(model?.isRunningSelfTest == true)
        } header: {
            Text("Helper self-test")
        } footer: {
            Text("Launches the bundled canfar-mcp exactly as Claude Desktop would and confirms it can initialize. Requires the server to be running. If the helper can't initialize its sandbox container, this is where you'll see it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
            Text("“Configure Claude Desktop” grants one-time access to the Claude config folder, then points the \(MCPIntegrationSettingsService.serverKey) entry at this app's helper. Only that entry is changed; a .bak backup is written first. Restart Claude Desktop after updating.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
#endif
