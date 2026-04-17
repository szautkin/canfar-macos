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

                // Sixth slot is the addon slot.
                //  - Installed first-party addons get their own tile (e.g.
                //    Notebook when Verbinal Pi is present).
                //  - With no addons installed, we show a single generic
                //    "Addons" placeholder that sends the user to the App Store
                //    catalog — avoids the graveyard-grid UX where every
                //    unknown addon claims its own dim tile.
                addonSlot
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

    // MARK: - Addon slot (sixth landing tile)

    @ViewBuilder
    private var addonSlot: some View {
        if let addon = appState.notebookAddon {
            // First-party addon installed → render its own tile.
            // Future: loop over `installedAddons` once there is more than one.
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
            // Nothing installed → generic placeholder pointing at the App
            // Store. Dashed outline signals "empty slot, tap to add".
            LandingTile(
                icon: "puzzlepiece.extension",
                fallbackIcon: "puzzlepiece.extension.fill",
                title: "Addons",
                subtitle: "Browse the App Store",
                dashedBorder: true
            ) {
                #if os(macOS)
                // Placeholder destination: App Store search scoped to our
                // developer name. When Pi is live on MAS, swap for its
                // product page URL (itms-apps://apps.apple.com/app/id…).
                if let url = URL(string: "macappstores://apps.apple.com/search?term=verbinal") {
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
    /// Dashed border + slightly dimmed content — signals "empty slot that
    /// the user can fill by installing something". Used for the generic
    /// Addons placeholder; not a per-addon state.
    var dashedBorder: Bool = false
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
            .opacity(dashedBorder ? 0.7 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .overlay(borderShape)
            .overlay(alignment: .topTrailing) {
                if let trustBadge {
                    Image(systemName: trustBadge)
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .padding(8)
                } else if dashedBorder {
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

    /// Solid 1pt for a regular tile, dashed for the addon placeholder.
    @ViewBuilder
    private var borderShape: some View {
        if dashedBorder {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    .secondary,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        } else {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.quaternary, lineWidth: 1)
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
