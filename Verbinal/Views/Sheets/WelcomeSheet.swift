// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// One-shot bookkeeping for the first-run Welcome card. Mirrors
/// `LegalAgreementService`'s versioned-acceptance pattern: store the Welcome
/// version the user last saw; bump `currentVersion` to re-surface the card
/// (e.g. after a major feature wave). `ContentView` reads/writes the key via
/// `@AppStorage`, so there is no service object to own here.
enum WelcomePreferences {
    /// Bump to re-show the Welcome card to everyone on the next launch.
    static let currentVersion = 1
    static let seenVersionKey = "verbinal.welcome.seenVersion"
}

/// B2 — first-run Welcome card. ONE dismissible card (explicitly NOT a
/// multi-step tour): a few pillar rows naming the breadth of the app, with a
/// prominent path into the AI-assistant wizard and a low-key "explore on my
/// own" dismiss. Presented once by `ContentView` after the Terms gate has
/// been accepted; it stamps `WelcomePreferences.seenVersionKey` on dismiss so
/// it never reappears for the current version.
///
/// macOS-only — it routes to the macOS-only MCP wizard; the iOS ContentView
/// switch maps `.welcome` to EmptyView.
struct WelcomeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WelcomePreferences.seenVersionKey) private var welcomeSeenVersion = 0

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image("VerbinalIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                Text("Welcome to Verbinal")
                    .font(.title.bold())
                Text("Your native companion for the CANFAR Science Platform.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                pillar(icon: "scope",
                       title: "Search & Research",
                       line: "Explore the CADC archive and organize your downloaded observations.")
                pillar(icon: "externaldrive.fill",
                       title: "Storage & FITS",
                       line: "Browse VOSpace and view astronomical images, Metal-accelerated.")
                pillar(icon: "shippingbox.and.arrow.backward",
                       title: "Image Discovery",
                       line: "See exactly what's inside a session image before you launch it.")
                pillar(icon: "wand.and.rays",
                       title: "AI assistant",
                       line: "Connect Claude Desktop or Claude Code (~60 tools) to drive Verbinal for you.")
            }
            .padding(.horizontal, 8)

            VStack(spacing: 10) {
                Button {
                    markSeen()
                    // Swap the single sheet host IN PLACE — do NOT dismiss() first.
                    // On an item-bound .sheet, dismiss() nils the binding async, so a
                    // same-tick reassignment races it and the wizard silently never
                    // appears. Reassigning the item lets the host swap content (the
                    // idiom FeaturesSheet already uses).
                    appState.activeSheet = .mcpSetupWizard
                } label: {
                    Label("Set up the AI assistant", systemImage: "wand.and.rays")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Explore on my own") {
                    markSeen()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    private func pillar(icon: String, title: LocalizedStringKey, line: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Stamp the current Welcome version so the card never reappears for it.
    private func markSeen() {
        welcomeSeenVersion = WelcomePreferences.currentVersion
    }
}
#endif
