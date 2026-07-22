// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Transient top-of-window banner shown whenever an MCP agent invokes a
/// tool (reads included), mirroring the Windows client's robot-icon
/// snackbar. Bursts coalesce into a running count; the banner
/// auto-dismisses shortly after the last call.
///
/// Hosted once on `ContentView`'s root ZStack so it floats above every
/// mode and survives mode cross-fades. Driven by
/// ``AgentLiveActivity`` (which lives on `AgentsService`).
struct AgentActivitySnackbar: View {
    var live: AgentLiveActivity

    var body: some View {
        VStack {
            if let banner = live.banner {
                content(banner)
                    .id(banner.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Spacer()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: live.banner)
        .allowsHitTesting(live.banner != nil)
    }

    @ViewBuilder
    private func content(_ banner: AgentLiveActivity.Banner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.rays")
                .foregroundStyle(.tint)
                .font(.callout.weight(.semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: true)

            VStack(alignment: .leading, spacing: 1) {
                Text(banner.originLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle(banner))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                live.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss agent activity")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(banner.originLabel) used \(banner.latestTool)")
    }

    private func subtitle(_ banner: AgentLiveActivity.Banner) -> String {
        if banner.count > 1 {
            return String(
                format: String(localized: "%d tool calls · %@"),
                banner.count, banner.latestTool)
        }
        return banner.latestTool
    }
}
