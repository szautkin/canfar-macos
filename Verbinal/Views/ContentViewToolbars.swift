// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Pure, view-agnostic decisions for what the toolbars should render.
///
/// Extracted so the conditional-rendering rules (omit empty status text)
/// can be unit-tested without a SwiftUI view host. The toolbars call these
/// directly, so the tests exercise the real rule.
enum ToolbarContent {

    /// Whether the toolbar status caption should be rendered at all.
    /// Empty status text is omitted so it reserves no layout space.
    static func showsStatusMessage(_ statusMessage: String) -> Bool {
        !statusMessage.isEmpty
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
                    // One line, always — a long "Cannot connect: …" must
                    // truncate, not wrap and change the toolbar height.
                    .lineLimit(1)
            }

            Spacer()

            agentProposalsToolbarItem

            fileBrowserToolbarItem

            settingsToolbarItem

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

            accountToolbarItem
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Settings cog, shared by every toolbar — landing, mode, and Portal —
    /// so the affordance never disappears when the user navigates into a
    /// module. `SettingsLink` (macOS 14+) opens the Settings scene.
    private var settingsToolbarItem: some View {
        SettingsLink {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Open Settings (⌘,)")
        .accessibilityLabel("Settings")
    }

    /// File-browser toggle, shared by every mode toolbar. The panel itself
    /// renders in ALL modes (it sits beside `mainContent`), so the toggle —
    /// and its ⌘B shortcut — must be reachable from every mode too;
    /// previously Portal had neither, leaving a panel opened elsewhere
    /// impossible to close without navigating away.
    private var fileBrowserToolbarItem: some View {
        Button {
            showFileBrowser.toggle()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("b", modifiers: [.command])
        .help("Toggle file browser (⌘B)")
        .accessibilityLabel(Text(showFileBrowser ? "Hide file browser" : "Show file browser"))
    }

    /// Profile / login control, shared by the landing and Portal toolbars
    /// so the account affordance is identical everywhere it appears (same
    /// icon, same menu, same sign-in style).
    @ViewBuilder
    private var accountToolbarItem: some View {
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

            fileBrowserToolbarItem

            settingsToolbarItem

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

    /// Pending changes — what assistants proposed, and every destructive
    /// change, which always waits there — one click away in every toolbar,
    /// Landing and Portal included, whether or not agents are on now (a
    /// change can wait from before). A badge counts what is waiting.
    @ViewBuilder
    private var agentProposalsToolbarItem: some View {
        let count = appState.agentsService.pendingProposals.count
        Button {
            appState.activeSheet = .agentProposals
        } label: {
            ZStack(alignment: .topTrailing) {
                Image.agentRobot
                    // One-shot bounce when the count arrives/changes — the
                    // app's "an agent did something" heartbeat. `value:`
                    // fires it exactly once per change (never repeating).
                    // RM nils the value (no glyph motion) but keeps a static
                    // glyph.
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
        .accessibilityLabel("Pending changes")
        .help("Pending changes — what your assistant proposed; destructive changes always wait here")
        .pointable("agent.pending", label: String(localized: "Pending changes"), screen: "window")
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
                    // One line, always — see the landing toolbar's note.
                    .lineLimit(1)
            }

            Spacer()

            agentProposalsToolbarItem

            fileBrowserToolbarItem

            settingsToolbarItem

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

            accountToolbarItem
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
#endif
