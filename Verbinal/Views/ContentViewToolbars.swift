// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Pure, view-agnostic decisions for what the toolbars should render.
///
/// Extracted so the conditional-rendering rules (omit empty status text,
/// omit a blank account-menu email row) can be unit-tested without a
/// SwiftUI view host, mirroring the `if !statusMessage.isEmpty` and
/// `if let email` guards used in the landing toolbar and `iOSAccountTab`.
enum ToolbarContent {

    /// Whether the toolbar status caption should be rendered at all.
    /// Empty status text is omitted so it reserves no layout space.
    static func showsStatusMessage(_ statusMessage: String) -> Bool {
        !statusMessage.isEmpty
    }

    /// Whether the account menu should render an email row.
    /// A nil email is omitted so the menu has no blank row.
    static func showsAccountEmail(_ email: String?) -> Bool {
        email != nil
    }
}

#if os(macOS)
extension ContentView {

    func makeLandingToolbar(showAbout: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            Text("Verbinal")
                .font(.headline)
            Text("- a CANFAR Science Portal")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if ToolbarContent.showsStatusMessage(appState.statusMessage) {
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                showFileBrowser.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("b", modifiers: [.command])
            .help("Toggle file browser (⌘B)")
            .accessibilityLabel(Text(showFileBrowser ? "Hide file browser" : "Show file browser"))

            // Settings — SettingsLink (macOS 14+) opens the Settings scene.
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Open Settings (⌘,)")
            .accessibilityLabel("Settings")

            Button {
                showAbout.wrappedValue = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("About Verbinal")
            .help("About Verbinal")

            if appState.isLoading {
                ProgressView().scaleEffect(0.7)
            }

            // Profile / login control — mirrors the Portal toolbar so users
            // see the same affordance across the app.
            if appState.isAuthenticated {
                Menu {
                    if let info = appState.userInfo {
                        Section {
                            if let email = info.email { Text(email) }
                            if let inst = info.institute { Text(inst) }
                        }
                    }
                    Divider()
                    Button("Sign Out") {
                        Task { await appState.logout() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle.fill")
                        if let info = appState.userInfo,
                           let first = info.firstName {
                            Text(verbatim: [first, info.lastName].compactMap { $0 }.joined(separator: " "))
                        } else {
                            Text(verbatim: appState.username)
                        }
                    }
                }
                .help("Your CADC account")
            } else {
                Button {
                    appState.showLoginSheet = true
                } label: {
                    Label("Sign In", systemImage: "person.crop.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Sign in to CADC to use Portal, Storage, and other authenticated services")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    func makeModeToolbar(title: String, showAbout: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Button {
                appState.navigateBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Go back")

            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            Text("Verbinal")
                .font(.headline)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // The chrome persists across the mode cross-fade (it lives
                // above the transitioning body); only this title changes when
                // switching among same-structure mode toolbars (Search →
                // Research → Storage → …), so cross-fade it in place rather
                // than hard-swapping. RM-aware via `.appAnimation`.
                .contentTransition(.opacity)
                .appAnimation(AppMotion.quick, value: title)

            Spacer()

            agentProposalsToolbarItem

            Button {
                showFileBrowser.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(showFileBrowser ? "Hide file browser" : "Show file browser")
            .help("Toggle file browser")

            Button {
                showAbout.wrappedValue = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("About Verbinal")
            .help("About Verbinal")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Toolbar shortcut to the agent-proposal strip. Visible only when
    /// the user has enabled external agents in Settings. A small badge
    /// shows the pending count when non-zero.
    @ViewBuilder
    private var agentProposalsToolbarItem: some View {
        if appState.agentsService.isEnabled {
            let count = appState.agentsService.pendingProposals.count
            Button {
                appState.activeSheet = .agentProposals
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "wand.and.rays")
                        // One-shot bounce when the count arrives/changes — the
                        // app's "an agent did something" heartbeat. `value:`
                        // fires it exactly once per change (never repeating).
                        // RM nils the value (no glyph motion) but keeps a static
                        // wand.
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : count)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold))
                            // Tween the digits instead of a hard swap.
                            .contentTransition(.numericText())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -6)
                            // Scale+fade the badge in/out. RM collapses to a
                            // plain cross-fade via `.appFade`.
                            .transition(
                                reduceMotion
                                    ? .appFade
                                    : .scale.combined(with: .opacity)
                            )
                    }
                }
                // Drive the count/badge changes through the RM-aware quick
                // settle so the numericText tween + insert/remove animate.
                .appAnimation(AppMotion.quick, value: count)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Agent proposals")
            .help("Review pending agent proposals")
        }
    }

    func makePortalToolbar(showAbout: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Button {
                appState.navigateBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Go back")

            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            Text("Verbinal")
                .font(.headline)
            Text("- a CANFAR Science Portal")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if ToolbarContent.showsStatusMessage(appState.statusMessage) {
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                showAbout.wrappedValue = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("About Verbinal")
            .help("About Verbinal")

            if appState.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            }

            if appState.isAuthenticated {
                Menu {
                    if let info = appState.userInfo {
                        Section {
                            if let email = info.email { Text(email) }
                            if let inst = info.institute {
                                Text(inst)
                            }
                        }
                    }
                    Divider()
                    Button("Sign Out") {
                        Task { await appState.logout() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.circle.fill")
                        if let info = appState.userInfo,
                           let first = info.firstName {
                            Text(verbatim: [first, info.lastName].compactMap { $0 }.joined(separator: " "))
                        } else {
                            Text(verbatim: appState.username)
                        }
                    }
                }
            } else {
                Button("Sign In") {
                    appState.showLoginSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
#endif
