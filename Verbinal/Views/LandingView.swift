// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

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

            // Tiles
            HStack(spacing: 24) {
                LandingTile(
                    icon: "scope",
                    fallbackIcon: "magnifyingglass.circle.fill",
                    title: "Search",
                    subtitle: "Explore the CADC archive"
                ) {
                    appState.currentMode = .search
                }

                LandingTile(
                    icon: "desktopcomputer",
                    fallbackIcon: "display",
                    title: "Portal",
                    subtitle: "Manage sessions & data"
                ) {
                    if appState.isAuthenticated {
                        appState.currentMode = .portal
                    } else {
                        appState.showLoginSheet = true
                        appState.pendingModeAfterLogin = .portal
                    }
                }

                LandingTile(
                    icon: "tray.full.fill",
                    fallbackIcon: "tray.full.fill",
                    title: "Research",
                    subtitle: "Downloaded observations"
                ) {
                    appState.currentMode = .research
                }
            }
            .padding(.horizontal, 32)

            if !appState.statusMessage.isEmpty {
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Landing Tile

private struct LandingTile: View {
    let icon: String
    let fallbackIcon: String
    let title: String
    let subtitle: String
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
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
