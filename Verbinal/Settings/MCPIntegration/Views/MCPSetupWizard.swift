// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

/// Guided "Connect your AI agent" setup sheet. A thin, presentation-only
/// front-end over the existing MCP plumbing — it owns NONE of the config /
/// diagnostics logic. The enable toggle drives `AgentsService.isEnabled`;
/// the configure / self-test actions call straight into
/// `MCPDiagnosticsModel` + `MCPIntegrationSettingsService`, so the one-way
/// secret / `.bak` backup / never-edit-`~/.claude.json` boundaries already in
/// those services are preserved unchanged.
///
/// Deliberately a small step machine with a progress header — NOT an
/// animated carousel/tour (per the discoverability plan's "tasteful ceiling").
/// Covers Claude Desktop + Claude Code; the `Client` enum is the seam where a
/// third client slots in later.
struct MCPSetupWizard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Lazily built on appear from the SAME services the Settings tab uses,
    /// so the wizard and Settings share one diagnostics/config code path.
    @State private var model: MCPDiagnosticsModel?
    @State private var step: Step = .enable
    @State private var client: Client = .claudeDesktop

    private var agents: AgentsService { appState.agentsService }
    private var settings: MCPIntegrationSettingsService { appState.mcpIntegrationSettings }

    // MARK: - Step machine

    /// The four guided steps. Linear; the header renders progress and the
    /// footer drives Back/Next. Kept tiny on purpose.
    enum Step: Int, CaseIterable {
        case enable, pickClient, configure, verify

        var title: String {
            switch self {
            case .enable:     "Allow AI agents"
            case .pickClient: "Pick your client"
            case .configure:  "Configure"
            case .verify:     "Verify"
            }
        }
    }

    /// The MCP clients the wizard can configure. Codex is intentionally
    /// deferred; the enum is the extension point for a third client.
    enum Client: String, CaseIterable, Identifiable {
        case claudeDesktop, claudeCode
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeDesktop: "Claude Desktop"
            case .claudeCode:    "Claude Code"
            }
        }
        var icon: String {
            switch self {
            case .claudeDesktop: "menubar.dock.rectangle"
            case .claudeCode:    "terminal"
            }
        }
        var blurb: String {
            switch self {
            case .claudeDesktop: "The desktop chat app. Verbinal can update its config for you."
            case .claudeCode:    "The CLI coding agent. Run one command to register Verbinal."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepBody
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 540)
        .onAppear {
            if model == nil {
                model = MCPDiagnosticsModel(agents: agents, settings: settings)
            }
            model?.runAll()
            // If agents are already on, skip the enable step so a returning
            // user lands straight on client selection.
            if agents.isEnabled, step == .enable {
                step = .pickClient
            }
        }
    }

    // MARK: - Header (progress)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.rays")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect your AI agent")
                        .font(.headline)
                    Text("Let Claude drive Verbinal — search the archive, manage sessions, and more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            // Lightweight step pips — labelled, not animated.
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    let isCurrent = s == step
                    let isDone = s.rawValue < step.rawValue
                    HStack(spacing: 5) {
                        Image(systemName: isDone ? "checkmark.circle.fill"
                              : (isCurrent ? "circle.fill" : "circle"))
                            .font(.caption2)
                            .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.secondary))
                        Text(s.title)
                            .font(.caption2)
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                    }
                    if s != Step.allCases.last {
                        Spacer(minLength: 0)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
        }
        .padding(20)
    }

    // MARK: - Step bodies

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .enable:     enableStep
        case .pickClient: pickClientStep
        case .configure:  configureStep
        case .verify:     verifyStep
        }
    }

    /// Step 1 — turn on the master switch. Auto-shows a check when already on.
    private var enableStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow external AI agents")
                .font(.title3.bold())
            Text("Verbinal stays private until you opt in. Turning this on starts a local MCP server that Claude connects to — nothing is exposed to the network.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if agents.isEnabled {
                Label("AI agents are allowed — the server is on.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button {
                    agents.isEnabled = true
                    model?.runAll()
                } label: {
                    Label("Turn on “Allow external AI agents”", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            GroupBox {
                MCPServerStatusRow(
                    isRunning: agents.isRunning,
                    socketPath: agents.socketPath,
                    lastError: agents.lastError
                )
            }
        }
    }

    /// Step 2 — choose Claude Desktop vs Claude Code.
    private var pickClientStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which client are you connecting?")
                .font(.title3.bold())
            Text("Pick the app you'll talk to Claude in. You can run the wizard again for the other one.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                ForEach(Client.allCases) { c in
                    clientCard(c)
                }
            }
        }
    }

    private func clientCard(_ c: Client) -> some View {
        let selected = client == c
        return Button {
            client = c
        } label: {
            VStack(spacing: 10) {
                Image(systemName: c.icon)
                    .font(.system(size: 36))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(c.displayName)
                    .font(.headline)
                Text(c.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Step 3 — client-specific configuration, reusing the existing services.
    @ViewBuilder
    private var configureStep: some View {
        switch client {
        case .claudeDesktop: configureClaudeDesktop
        case .claudeCode:    configureClaudeCode
        }
    }

    private var configureClaudeDesktop: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Claude Desktop")
                .font(.title3.bold())
            Text("This grants one-time access to Claude's config folder, then points the “\(MCPIntegrationSettingsService.serverKey)” entry at this app, launched in MCP mode. Only that entry changes; a .bak backup is written first.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                model?.configureClaude()
            } label: {
                Label("Configure Claude Desktop", systemImage: "gearshape.2")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

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
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let err = model?.actionError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var configureClaudeCode: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Claude Code")
                .font(.title3.bold())
            Text("Claude Code keeps MCP servers in ~/.claude.json alongside auth tokens, so Verbinal never edits it directly. Run this command in a terminal to register Verbinal the safe, official way:")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                HStack(alignment: .top) {
                    Text(settings.claudeCodeAddCommand())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy") { settings.copyClaudeCodeAddCommand() }
                        .controlSize(.small)
                }
                .padding(6)
            }

            DisclosureGroup("Prefer to hand-edit ~/.claude.json?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste this into the top-level mcpServers object:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(settings.claudeCodeConfigSnippet())
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Copy JSON Snippet") { settings.copyClaudeCodeSnippet() }
                            .controlSize(.small)
                        Button("Reveal Config") { settings.revealClaudeCodeConfig() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    /// Step 4 — run the MCP server self-test and prompt a client relaunch.
    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify the connection")
                .font(.title3.bold())
            Text("Your AI client launches Verbinal itself in MCP mode. This confirms the MCP server is reachable; the final proof is restarting your client and seeing the Verbinal tools appear.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                Task { await model?.runSelfTest() }
            } label: {
                if model?.isRunningSelfTest == true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Running self-test…")
                    }
                } else {
                    Label("Run self-test", systemImage: "stethoscope")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model?.isRunningSelfTest == true)

            if let test = model?.selfTest {
                GroupBox {
                    MCPDiagnosticRow(check: test) { model?.applyFix($0) }
                }
            }

            GroupBox {
                Label("Now fully quit and relaunch \(client.displayName), then confirm the Verbinal tools appear.",
                      systemImage: "arrow.clockwise")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer (navigation)

    private var footer: some View {
        HStack {
            if step != Step.allCases.first {
                Button("Back") { goBack() }
                    .controlSize(.large)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            if step == .verify {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { goNext() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAdvance)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    /// The enable step blocks Next until the master switch is on; every
    /// other step advances freely.
    private var canAdvance: Bool {
        if step == .enable { return agents.isEnabled }
        return true
    }

    private func goNext() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        if next == .verify { model?.runAll() }
        step = next
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }
}
#endif
