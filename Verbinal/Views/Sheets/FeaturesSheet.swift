// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

/// B1 — the "What Verbinal Can Do" index. A scrollable grouped list of the
/// real capabilities, each with an icon, one honest line (copy lifted from
/// the existing Settings footers / landing subtitles, not rewritten), and an
/// Open / Set-Up action. The single missing cross-feature discovery surface
/// that the Welcome card, Help menu, and About all link into.
///
/// macOS-only: every capability listed here (FITS, Storage, Image Discovery,
/// the MCP agent) is macOS-only or routes through a macOS-only sheet, and the
/// action verbs (`navigateTo`, `activeSheet`, `SettingsLink`) target the
/// desktop shell. The iOS ContentView switch routes `.features` to EmptyView.
struct FeaturesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    section("Explore & organize") {
                        FeatureRow(
                            icon: "scope",
                            title: "Search",
                            line: "Explore the CADC archive — query observations and refine with constraints.",
                            actionLabel: "Open"
                        ) { open(.search) }

                        FeatureRow(
                            icon: "tray.full.fill",
                            title: "Research",
                            line: "Your downloaded observations and notes, in one searchable place.",
                            actionLabel: "Open"
                        ) { open(.research) }

                        FeatureRow(
                            icon: "externaldrive.fill",
                            title: "Storage",
                            line: "Browse VOSpace files. macOS only.",
                            actionLabel: "Open"
                        ) { open(.storage) }

                        FeatureRow(
                            icon: "star.circle.fill",
                            title: "FITS Viewer",
                            line: "View astronomical images, Metal-accelerated. macOS only.",
                            actionLabel: "Open"
                        ) { open(.fitsViewer) }
                    }

                    section("On the platform") {
                        FeatureRow(
                            icon: "shippingbox.and.arrow.backward",
                            title: "Image Discovery",
                            line: "See what's inside a session image — probe-job-driven, locally cached package introspection. macOS only.",
                            actionLabel: "Open"
                        ) { openImageDiscovery() }
                    }

                    section("AI") {
                        FeatureRow(
                            icon: "wand.and.rays",
                            title: "AI Agent / MCP",
                            line: "MCP-compatible AI clients (Claude Desktop, Claude Code) can drive Verbinal, which runs as a local MCP server. macOS only.",
                            actionLabel: "Set Up"
                        ) { appState.activeSheet = .mcpSetupWizard }

                        FeatureRow(
                            icon: "wand.and.stars",
                            title: "AI Guide",
                            line: "Re-tune the descriptions the MCP server advertises for each tool, and author your own read-only instruction tools. macOS only.",
                            actionLabel: "Open"
                        ) { open(.aiGuide) }

                        FeatureRow(
                            icon: "cpu",
                            title: "AI Compute",
                            line: "Let the agent run code on a contributed session via the run_code tool. Configure the compute image in Settings. macOS only.",
                            actionLabel: settingsLinkSlot
                        )
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("What Verbinal Can Do")
                    .font(.headline)
                Text("Everything in one place — open a feature or set up the AI assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            GroupBox {
                VStack(spacing: 0) {
                    content()
                }
            }
        }
    }

    /// AI Compute is reached through Settings (no dedicated mode), so its
    /// action is a `SettingsLink` rather than a plain button. Dismissing the
    /// sheet first keeps the Settings window from opening behind a modal.
    private var settingsLinkSlot: some View {
        SettingsLink {
            Text("Settings")
        }
        .controlSize(.small)
        .simultaneousGesture(TapGesture().onEnded { dismiss() })
    }

    // MARK: - Actions

    private func open(_ mode: AppMode) {
        dismiss()
        appState.navigateTo(mode)
    }

    private func openImageDiscovery() {
        dismiss()
        appState.showImageDiscoverySheet = true
    }
}

// MARK: - Feature row

/// One capability row: icon + title + one honest line + a trailing action.
/// The action is type-erased so a plain Button row and a `SettingsLink` row
/// share the same layout.
private struct FeatureRow<Action: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let line: LocalizedStringKey
    let action: Action

    /// Button convenience init — the common case.
    init(icon: String, title: LocalizedStringKey, line: LocalizedStringKey,
         actionLabel: LocalizedStringKey, perform: @escaping () -> Void)
    where Action == Button<Text> {
        self.icon = icon
        self.title = title
        self.line = line
        self.action = Button(actionLabel, action: perform)
    }

    /// Custom-trailing-control init (e.g. a `SettingsLink`).
    init(icon: String, title: LocalizedStringKey, line: LocalizedStringKey,
         actionLabel: Action) {
        self.icon = icon
        self.title = title
        self.line = line
        self.action = actionLabel
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action
                .controlSize(.small)
        }
        .padding(.vertical, 8)
    }
}
#endif
