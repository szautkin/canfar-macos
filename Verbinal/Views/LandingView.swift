// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit
#if os(macOS)
import AppKit
#endif

struct LandingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App branding
            VStack(spacing: 12) {
                Image("VerbinalIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                Text("Verbinal")
                    .font(.largeTitle.bold())
                Text("A CANFAR Science Portal Companion")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Tiles: 3 columns × 2 rows
            let tileColumns = [
                GridItem(.fixed(200), spacing: 20),
                GridItem(.fixed(200), spacing: 20),
                GridItem(.fixed(200), spacing: 20),
            ]

            LazyVGrid(columns: tileColumns, spacing: 20) {
                LandingTile(
                    icon: "desktopcomputer",
                    fallbackIcon: "display",
                    title: "Portal",
                    subtitle: "Manage sessions & data"
                ) {
                    appState.navigateTo(.portal)
                }

                LandingTile(
                    icon: "scope",
                    fallbackIcon: "magnifyingglass.circle.fill",
                    title: "Search",
                    subtitle: "Explore the CADC archive"
                ) {
                    appState.navigateTo(.search)
                }

                LandingTile(
                    icon: "tray.full.fill",
                    fallbackIcon: "tray.full.fill",
                    title: "Research",
                    subtitle: "Downloaded observations"
                ) {
                    appState.navigateTo(.research)
                }

                LandingTile(
                    icon: "externaldrive.fill",
                    fallbackIcon: "externaldrive.fill",
                    title: "Storage",
                    subtitle: "Browse VOSpace files"
                ) {
                    appState.navigateTo(.storage)
                }

                LandingTile(
                    icon: "star.circle.fill",
                    fallbackIcon: "star.circle.fill",
                    title: "FITS Viewer",
                    subtitle: "View astronomical images"
                ) {
                    appState.navigateTo(.fitsViewer)
                }

                // Notebook tile — addon. If Pi is installed, tile launches it
                // via URL scheme; otherwise we suggest downloading Pi.
                notebookTile
            }

            if !appState.statusMessage.isEmpty {
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { appState.refreshAddons() }
    }

    // MARK: - Notebook tile (Verbinal Pi addon)

    @ViewBuilder
    private var notebookTile: some View {
        if let addon = appState.notebookAddon {
            // Installed — launch via AddonRegistry URL activation.
            LandingTile(
                icon: addon.manifest.systemIconName ?? "terminal",
                fallbackIcon: "doc.text",
                title: addon.manifest.displayName,
                subtitle: addon.manifest.subtitle,
                trustBadge: addon.manifest.trustBadge
            ) {
                _ = appState.addonRegistry.activate(addon, context: .launchEmpty)
            }
        } else {
            // Not installed — show a dim tile that links out to the
            // distribution channel (App Store eventually; homepage for now).
            LandingTile(
                icon: "terminal",
                fallbackIcon: "doc.text",
                title: "Notebook",
                subtitle: "Get Verbinal Pi",
                installPrompt: true
            ) {
                #if os(macOS)
                // Placeholder: App Store product page URL wired in Phase 8
                // of the plan. Today we open the project homepage.
                if let url = URL(string: "https://github.com/szautkin/canfar-macos") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
        }
    }
}

// Trust-badge SF Symbol derived from manifest.trust. Defined on the manifest
// so every place that renders a trust indicator agrees on the glyph.
private extension AddonManifest {
    var trustBadge: String? {
        switch trust {
        case .official: return "checkmark.seal.fill"
        case .community: return "seal"
        }
    }
}

// MARK: - Landing Tile

private struct LandingTile: View {
    let icon: String
    let fallbackIcon: String
    let title: String
    let subtitle: String
    var trustBadge: String? = nil
    var installPrompt: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: iconName)
                    .font(.system(size: 48))
                    .foregroundStyle(isHovering ? .primary : .secondary)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.title2.bold())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 180)
            .opacity(installPrompt ? 0.65 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if let trustBadge {
                    Image(systemName: trustBadge)
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .padding(8)
                } else if installPrompt {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(subtitle)")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var iconName: String {
        // Check if the primary SF Symbol exists, otherwise use fallback
        #if os(macOS)
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
            return icon
        }
        #else
        if UIImage(systemName: icon) != nil {
            return icon
        }
        #endif
        return fallbackIcon
    }
}
