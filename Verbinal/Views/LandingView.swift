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
    /// User toggle (Settings ▸ MCP Clients) to show/hide the AI Guide launchpad tile.
    /// OFF by default — the tile is hidden until the user opts in; enabling it only
    /// adds the shortcut (the feature/overrides are unaffected either way).
    @AppStorage(AIGuidePreferences.showLandingTileKey) private var showAIGuideTile = false

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
                // Portal + Storage need the CADC token; lock them when not
                // signed in. Tapping a locked tile remembers the intended
                // destination and opens the login sheet — AppState.updateAuthState
                // navigates there automatically on successful sign-in.
                LandingTile(
                    icon: "desktopcomputer",
                    fallbackIcon: "display",
                    title: "Portal",
                    subtitle: "Manage sessions & data",
                    locked: !appState.isAuthenticated
                ) {
                    navigateOrPromptLogin(.portal)
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
                    subtitle: "Browse VOSpace files",
                    locked: !appState.isAuthenticated
                ) {
                    navigateOrPromptLogin(.storage)
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

                #if os(macOS)
                // AI Guide — inspect/re-tune the MCP tool surface the agent
                // sees, and author custom instruction tools. macOS-only: the
                // MCP server (and its tools) exist only on the desktop build.
                // Hidden when the user turns it off in Settings ▸ MCP Clients.
                if showAIGuideTile {
                    LandingTile(
                        icon: "wand.and.stars",
                        fallbackIcon: "sparkles",
                        title: "AI Guide",
                        subtitle: "Tune the agent's tools"
                    ) {
                        appState.navigateTo(.aiGuide)
                    }
                }
                #endif
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

    // MARK: - Auth-gated navigation

    /// Navigates to `mode` if the user is signed in. Otherwise remembers the
    /// intent in `pendingModeAfterLogin` and opens the login sheet —
    /// `AppState.updateAuthState` will complete the navigation on success.
    private func navigateOrPromptLogin(_ mode: AppMode) {
        if appState.isAuthenticated {
            appState.navigateTo(mode)
        } else {
            appState.pendingModeAfterLogin = mode
            appState.showLoginSheet = true
        }
    }

    // MARK: - Addon slot (sixth landing tile)

    @ViewBuilder
    private var addonSlot: some View {
        if let addon = appState.notebookAddon {
            // First-party addon installed → render its own tile.
            // Manifest strings are English in the plist; wrapping with
            // LocalizedStringKey runs them through the catalog so first-
            // party translations take effect. Missing keys fall back to
            // the raw manifest string — correct for community addons.
            LandingTile(
                icon: addon.manifest.systemIconName ?? "terminal",
                fallbackIcon: "doc.text",
                title: LocalizedStringKey(addon.manifest.displayName),
                subtitle: LocalizedStringKey(addon.manifest.subtitle),
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
    /// Declared as `LocalizedStringKey` so string-literal call sites auto-
    /// route through the String Catalog. For dynamic strings (e.g. addon
    /// manifest `displayName`), wrap with `LocalizedStringKey(_:)` at the
    /// call site — the lookup still happens; missing keys fall back to
    /// the raw string.
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var trustBadge: String? = nil
    /// Dashed border + slightly dimmed content — signals "empty slot that
    /// the user can fill by installing something". Used for the generic
    /// Addons placeholder; not a per-addon state.
    var dashedBorder: Bool = false
    /// Auth-gated tile. Renders a lock badge, a "Sign in to …" tooltip,
    /// and dims the content. Tap action is still fired — the caller is
    /// responsible for opening the login flow.
    var locked: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .opacity(dashedBorder || locked ? 0.7 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .overlay(borderShape)
            .overlay(alignment: .topTrailing) { cornerBadge }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .help(locked ? LocalizedStringKey("Sign in to access this feature") : "")
        .onHover { hovering in
            withAppAnimation(AppMotion.quick, reduceMotion: reduceMotion) {
                isHovering = hovering
            }
        }
    }

    /// Top-trailing overlay — lock + trust-badge + install-arrow compete
    /// for the same corner; locked wins when active because it's a
    /// blocking state (user cannot get past it without action).
    @ViewBuilder
    private var cornerBadge: some View {
        if locked {
            Image(systemName: "lock.fill")
                .font(.caption)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(8)
        } else if let trustBadge {
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
