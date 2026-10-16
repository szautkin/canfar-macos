// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

/// Top-level Preferences window (⌘,). Tabbed layout following the macOS HIG for
/// System Settings-style apps (Mail, Xcode, Music).
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.settingsSection) {
            GeneralSettingsTab()
                .pointableArea("settings.general", label: String(localized: "General"))
                .environment(appState)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsSection.general)

            PortalSettingsTab()
                .pointableArea("settings.portal", label: String(localized: "Portal"))
                .environment(appState)
                .tabItem { Label("Portal", systemImage: "play.circle") }
                .tag(SettingsSection.portal)

            // Master switch first, then the features that depend on it
            // (Image Discovery probe jobs, AI Compute), then the
            // external-client setup that talks to the server.
            AgentsSettingsTab()
                .pointableArea("settings.agent", label: String(localized: "AI Agent"))
                .environment(appState)
                .tabItem { Label("AI Agent", image: "robot") }
                .tag(SettingsSection.agent)

            ImageDiscoverySettingsTab()
                .pointableArea("settings.imageDiscovery", label: String(localized: "Image Discovery"))
                .environment(appState)
                .tabItem { Label("Image Discovery", systemImage: "shippingbox.and.arrow.backward") }
                .tag(SettingsSection.imageDiscovery)

            AIComputeSettingsTab()
                .pointableArea("settings.aiCompute", label: String(localized: "AI Compute"))
                .environment(appState)
                .tabItem { Label("AI Compute", systemImage: "cpu") }
                .tag(SettingsSection.aiCompute)

            #if os(macOS)
            StorageSettingsTab()
                .pointableArea("settings.storage", label: String(localized: "Storage"))
                .environment(appState)
                .tabItem { Label("Storage", systemImage: "externaldrive.connected.to.line.below") }
                .tag(SettingsSection.storage)
            #endif

            MCPIntegrationSettingsTab()
                .pointableArea("settings.mcpClients", label: String(localized: "MCP Clients"))
                .environment(appState)
                .tabItem { Label("MCP Clients", systemImage: "network") }
                .tag(SettingsSection.mcpClients)

            EndpointsSettingsTab()
                .pointableArea("settings.endpoints", label: String(localized: "Endpoints"))
                .environment(appState)
                .tabItem { Label("Endpoints", systemImage: "server.rack") }
                .tag(SettingsSection.endpoints)

            AboutSettingsTab()
                .pointableArea("settings.about", label: String(localized: "About"))
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsSection.about)
        }
        // Resizable instead of a fixed 420 height: the AI Agent tab can
        // stack the autonomy controls + a ~160pt nested activity
        // ScrollView, which a hard 420 traps. A sensible minimum keeps
        // the modal from collapsing.
        .frame(minWidth: 520, idealWidth: 520, minHeight: 420, idealHeight: 520)
        // close_settings: the window closes itself.
        .onChange(of: appState.settingsRequest) { _, request in
            if request?.action == .close { dismiss() }
        }
    }
}

#if os(macOS)
/// Opens the Settings window when app state asks (open_settings). Lives in
/// the main window, which has the `openSettings` action.
struct SettingsOpener: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: appState.settingsRequest) { _, request in
                if request?.action == .open { openSettings() }
            }
    }
}
#endif

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState

    /// Bridges AppState.preferredLocaleIdentifier (UserDefaults-backed) to a
    /// SwiftUI Picker binding so selection writes-through on change and
    /// re-renders the whole app via the .environment(\.locale) at the root.
    private var localeBinding: Binding<String> {
        Binding(
            get: { appState.preferredLocaleIdentifier },
            set: { appState.preferredLocaleIdentifier = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: localeBinding) {
                    Text("System").tag("system")
                    Text("English").tag("en")
                    Text("Français").tag("fr")
                } label: {
                    Label("Language", systemImage: "globe")
                }
                .pickerStyle(.menu)

                if appState.languageChangePendingRelaunch {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundStyle(.tint)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restart required")
                                .font(.callout.bold())
                            Text("Verbinal needs to restart to apply the new language.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restart Now") {
                            appState.relaunch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Quit and relaunch Verbinal to apply the new language")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Language")
            } footer: {
                Text("macOS applies app-language overrides at launch. Changing this setting writes the preference; the next launch picks it up.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            DownloadFolderSection()
            #endif
        }
        .formStyle(.grouped)
    }
}

// MARK: - Agents tab

private struct AgentsSettingsTab: View {
    @Environment(AppState.self) private var appState

    private var allowExternalAgents: Binding<Bool> {
        Binding(
            get: { appState.agentsService.isEnabled },
            set: { appState.agentsService.isEnabled = $0 }
        )
    }

    private var followAgentActivity: Binding<Bool> {
        Binding(
            get: { appState.agentsService.followAgentActivity },
            set: { appState.agentsService.followAgentActivity = $0 }
        )
    }

    private var showActivitySnackbar: Binding<Bool> {
        Binding(
            get: { appState.agentsService.liveActivity.isEnabled },
            set: { appState.agentsService.liveActivity.setEnabled($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow external AI agents", isOn: allowExternalAgents)
                    .toggleStyle(.switch)
                    .pointable("settings.agent.allowExternal")
                statusRow
            } header: {
                Text("MCP Server")
            } footer: {
                Text("When enabled, MCP-compatible AI clients (Claude Desktop, etc.) " +
                     "can call into Verbinal, which runs as a local MCP server. " +
                     "Read tools run directly; what an assistant changes follows " +
                     "the settings below.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if appState.agentsService.isEnabled {
                ChangePermissionsSection(agents: appState.agentsService)
                Section {
                    Toggle("Follow agent activity", isOn: followAgentActivity)
                        .toggleStyle(.switch)
                        .pointable("settings.agent.follow")
                    Toggle("Show activity snackbar", isOn: showActivitySnackbar)
                        .toggleStyle(.switch)
                    Toggle("Play a sound when an agent starts and stops", isOn: Bindable(appState.agentsService.sounds).isEnabled)
                        .toggleStyle(.switch)
                        .pointable("settings.agent.sounds")
                } header: {
                    Text("Autonomy")
                } footer: {
                    Text("Follow agent activity jumps the window to where an assistant's change is visible (the explicit `navigate_to` tool ignores this toggle). " +
                         "Activity snackbar flashes a banner at the top of the window whenever an agent uses a tool; " +
                         "the sounds mark when one starts and when it has gone quiet, for when you are looking elsewhere.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if appState.agentsService.isRunning {
                Section {
                    diagnosticsRow
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("View live activity in Console.app via " +
                         "`log show --predicate 'subsystem == \"com.codebg.Verbinal.agent\"'`.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Label("\(appState.agentsService.activityStore.entries.count) entries",
                              systemImage: "clock.arrow.circlepath")
                            .font(.callout)
                        Spacer()
                        Button("Clear", role: .destructive) {
                            appState.agentsService.activityStore.clear()
                        }
                        .controlSize(.small)
                        .disabled(appState.agentsService.activityStore.entries.isEmpty)
                        .help("Erase the agent-activity breadcrumb log")
                    }
                } header: {
                    Text("Activity History")
                } footer: {
                    Text("Persistent breadcrumb of agent applies, rejections, and " +
                         "live UI ops. Bodies / payloads are never stored — only " +
                         "the same compact summary that showed in the proposal strip.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    auditList
                } header: {
                    Text("Recent Activity")
                } footer: {
                    Text("Hashes and outcomes only — call arguments are never logged.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            #if os(macOS)
            SessionIdleSection()
            SessionInstructionsSection()
            SessionLogsSection()
            #endif
        }
        .formStyle(.grouped)
    }

    /// The single authoritative server-status row. The MCP Clients tab
    /// shows the same `MCPServerStatusRow` in `.compact` form so the two
    /// tabs can't drift in wording.
    private var statusRow: some View {
        MCPServerStatusRow(
            isRunning: appState.agentsService.isRunning,
            socketPath: appState.agentsService.socketPath,
            lastError: appState.agentsService.serverProblem?.message
        )
    }

    private var diagnosticsRow: some View {
        HStack {
            Label("\(appState.agentsService.connectionCount) active",
                  systemImage: "personalhotspot")
            Spacer()
            Label("\(appState.agentsService.tools.count) tool\(appState.agentsService.tools.count == 1 ? "" : "s") registered",
                  systemImage: "wrench.and.screwdriver")
        }
        .font(.callout)
    }

    private var auditList: some View {
        // Plain Form rows (no nested ScrollView-in-Form): the 5 most recent
        // calls, newest first, with a caption noting the truncation.
        let entries = appState.agentsService.recentAuditEntries(limit: 5)
        return Group {
            if entries.isEmpty {
                Text("No agent calls yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.reversed(), id: \.requestID) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: entry))
                            .foregroundStyle(color(for: entry))
                            .accessibilityLabel(accessibilityLabel(for: entry))
                        Text(entry.toolName)
                            .font(.caption.monospaced())
                        Text(entry.outcome.tag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !entry.originLabel.isEmpty, entry.originLabel != "user" {
                            Text(entry.originLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("client \(entry.origin.tag)")
                        }
                        Spacer()
                        Text("\(entry.durationMS) ms")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if entries.count == 5 {
                    Text("Showing the 5 most recent")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func icon(for entry: AuditEntry) -> String {
        switch entry.outcome {
        case .ok, .data: return "checkmark.circle"
        case .proposed: return "tray.and.arrow.down"
        case .applied: return "wand.and.stars"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func color(for entry: AuditEntry) -> Color {
        switch entry.outcome {
        case .ok, .data: return .green
        case .proposed: return .blue
        case .applied: return .purple
        case .failed: return .orange
        }
    }

    /// Spoken description of the color-coded outcome icon so VoiceOver
    /// conveys state, not just the adjacent tool name.
    private func accessibilityLabel(for entry: AuditEntry) -> String {
        switch entry.outcome {
        case .ok, .data: return "Succeeded"
        case .proposed: return "Proposed"
        case .applied: return "Applied"
        case .failed: return "Failed"
        }
    }
}

// MARK: - About tab

private struct AboutSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "telescope.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Verbinal")
                .font(.title2.bold())
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("A native CANFAR companion for Search, Research, Storage, and FITS — with an optional AI agent that drives it for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Features…") {
                appState.activeSheet = .features
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
