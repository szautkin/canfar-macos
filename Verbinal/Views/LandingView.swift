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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// User toggle (Settings ▸ MCP Clients) to show/hide the AI Guide launchpad tile.
    /// OFF by default — the tile is hidden until the user opts in; enabling it only
    /// adds the shortcut (the feature/overrides are unaffected either way).
    @AppStorage(AIGuidePreferences.showLandingTileKey) private var showAIGuideTile = false

    var body: some View {
        // The GeometryReader supplies the container size (the deployment
        // target is macOS 14, where the newer `.onGeometryChange` isn't
        // available): width drives the adaptive column count, and height
        // becomes the scroll content's minHeight so the Spacer-centered
        // layout stays vertically centered when it fits — and scrolls,
        // instead of clipping tiles, when the window is short (at the
        // 900×600 window minimum the grid + branding already overflow).
        GeometryReader { proxy in
            ScrollView(.vertical) {
                launchpad(availableWidth: proxy.size.width)
                    .padding(.vertical, 20)
                    .frame(width: proxy.size.width)
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // The connectivity banner floats over the bottom edge instead of
        // living in the scrollable flow: appearing must not reflow the
        // centered launchpad, and a state banner must not scroll out of
        // sight in a short window.
        .overlay(alignment: .bottom) { connectivityBanner }
        .appAnimation(AppMotion.quick, value: appState.authAwaitingConnectivity)
        .task { appState.refreshAddons() }
    }

    /// Sign-in is parked until the network returns. One actionable row:
    /// the controller's explanation (offline vs cannot-connect) plus the
    /// manual retry. The general `statusMessage` is NOT rendered on the
    /// page — the landing toolbar already shows it.
    @ViewBuilder
    private var connectivityBanner: some View {
        if appState.authAwaitingConnectivity {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(appState.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Try Again") {
                    Task { await appState.initialize() }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // Material, not a flat fill — the banner overlaps scrollable
            // content, so it needs its own legible surface.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
            .frame(maxWidth: 560)
            .padding(.bottom, 16)
            .transition(reduceMotion ? .appFade : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func launchpad(availableWidth: CGFloat) -> some View {
        VStack(spacing: 32) {
            Spacer()

            // App branding
            VStack(spacing: 12) {
                Image("VerbinalIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)
                Text("Verbinal")
                    .font(.largeTitle.bold())
                Text("A CANFAR Science Portal Companion")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Adaptive column count, clamped to [3, 5] by available width —
            // mirrors Windows 1.3.0's UpdateTileColumns. Each tile is 200pt
            // wide with 20pt gutters; the clamp also covers the first layout
            // pass, where the measured width can still be 0.
            let tileColumnCount = min(5, max(3, Int((availableWidth + 20) / (200 + 20))))
            let tileColumns = Array(
                repeating: GridItem(.fixed(200), spacing: 20),
                count: tileColumnCount
            )

            LazyVGrid(columns: tileColumns, spacing: 20) {
                // As on Verbinal for Windows: the account's own screens first
                // (Portal, Remote Compute, Storage — locked until sign-in; a
                // tap remembers the destination and opens the login sheet),
                // then the archive, the viewers, the notebook and workflows,
                // and the AI Guide and AI Assistant last.
                LandingTile(
                    icon: "desktopcomputer",
                    fallbackIcon: "display",
                    title: "Portal",
                    subtitle: "Manage sessions & data",
                    locked: !appState.isAuthenticated
                ) {
                    navigateOrPromptLogin(.portal)
                }

                #if os(macOS)
                // Remote Compute — the compute session an assistant's run_code
                // uses, its runs, and a box to run code yourself. Needs the
                // CADC session, like Portal and Storage.
                LandingTile(
                    icon: "cpu",
                    fallbackIcon: "cpu",
                    title: "Remote Compute",
                    subtitle: "Run code on your CANFAR session",
                    locked: !appState.isAuthenticated
                ) {
                    navigateOrPromptLogin(.remoteCompute)
                }
                #endif

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
                    icon: "star.circle.fill",
                    fallbackIcon: "star.circle.fill",
                    title: "FITS Viewer",
                    subtitle: "View astronomical images"
                ) {
                    appState.navigateTo(.fitsViewer)
                }

                LandingTile(
                    icon: "cube.transparent.fill",
                    fallbackIcon: "cube.fill",
                    title: "Cube Viewer",
                    subtitle: "Explore 3D spectral cubes"
                ) {
                    appState.navigateTo(.cubeViewer)
                }

                // The addon slot, where Windows has its Notebook tile.
                //  - Installed first-party addons get their own tile (e.g.
                //    Notebook when Verbinal Pi is present).
                //  - With no addons installed, we show a single generic
                //    "Addons" placeholder that sends the user to the App Store
                //    catalog — avoids the graveyard-grid UX where every
                //    unknown addon claims its own dim tile.
                addonSlot

                LandingTile(
                    icon: "checklist",
                    fallbackIcon: "checklist",
                    title: "Workflows",
                    subtitle: "Follow reusable research protocols"
                ) {
                    appState.navigateTo(.workflows)
                }

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

                // AI Assistant — the newcomer-framed entry point to the MCP
                // setup wizard. Always shown (macOS-only); distinct from the
                // AI Guide tile, which presumes the agent is already connected.
                // Opening it presents the guided "Connect your AI agent" sheet.
                LandingTile(
                    icon: "robot",
                    fallbackIcon: "sparkles",
                    title: "AI Assistant",
                    subtitle: "Connect Claude to drive Verbinal"
                ) {
                    appState.activeSheet = .mcpSetupWizard
                }
                #endif
            }

            Spacer()
        }
    }

    // MARK: - Auth-gated navigation

    private func navigateOrPromptLogin(_ mode: AppMode) {
        appState.navigateOrPromptLogin(mode)
    }

    // MARK: - Addon slot

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

/// Plain-look tile button that actually responds to the click: a quick
/// scale dip while pressed (an opacity dim instead under Reduce Motion).
/// `.plain` gave zero pressed-state feedback — hover was the only visual
/// response a tile ever produced.
private struct LandingTileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1.0)
            .opacity(reduceMotion && configuration.isPressed ? 0.8 : 1.0)
            .appAnimation(AppMotion.quick, value: configuration.isPressed)
    }
}

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
        // Locked tiles carry the tooltip and announce their state to
        // VoiceOver; unlocked tiles get neither (the old unconditional
        // `.help("")` registered an empty tooltip on every tile).
        if locked {
            tileButton
                .help("Sign in to access this feature")
                .accessibilityValue(Text("Locked"))
                .accessibilityHint(Text("Sign in to access this feature"))
        } else {
            tileButton
                .accessibilityHint(Text(subtitle))
        }
    }

    private var tileButton: some View {
        Button(action: action) {
            // Three rigid zones so icons and titles line up across every tile
            // regardless of how the (localized) title wraps. Icon and title
            // bands are fixed-height; the subtitle fills the remainder.
            VStack(spacing: 16) {
                // Icon band — fixed height keeps every title's baseline aligned.
                Image(symbol: iconName)
                    .font(.system(size: 48))
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .frame(height: 56)

                // Title band — fixed height fits two lines of .title2.bold, so
                // single- and double-line titles occupy the same vertical space.
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(height: 56)

                // Subtitle band — fills the remainder, wrapping to two lines.
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            // Even breathing room on all sides — the icon band must not
            // sit flush against the rounded border. The tile height is
            // the three fixed bands (56 + 56 + 36) + two 16pt gaps + the
            // 16pt insets top and bottom.
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(width: 200, height: 212)
            .opacity(dashedBorder || locked ? 0.7 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .overlay(borderShape)
            .overlay(alignment: .topTrailing) { cornerBadge }
        }
        .buttonStyle(LandingTileButtonStyle())
        .accessibilityLabel(Text(title))
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
        // Keep the primary icon when it resolves as a system SF Symbol or
        // a custom catalog symbol (e.g. "robot"); otherwise use fallback.
        #if os(macOS)
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil
            || NSImage(named: icon) != nil {
            return icon
        }
        #else
        if UIImage(systemName: icon) != nil || UIImage(named: icon) != nil {
            return icon
        }
        #endif
        return fallbackIcon
    }
}
