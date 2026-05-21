// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

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

            if !appState.statusMessage.isEmpty {
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
            Button {
                appState.activeSheet = .agentProposals
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "wand.and.rays")
                    let count = appState.agentsService.pendingProposals.count
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -6)
                    }
                }
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

            Text(appState.statusMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)

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
                            Text(info.email ?? "")
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
