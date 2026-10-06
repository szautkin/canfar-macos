// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SessionCardView: View {
    let session: Session
    var onOpen: () -> Void
    var onDelete: () -> Void
    var onRenew: () -> Void
    var onEvents: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Icon + status
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(typeColor.opacity(0.15))
                    if let assetName = typeImageAsset {
                        Image(assetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: typeIcon)
                            .font(.title3)
                            .foregroundStyle(typeColor)
                    }
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(ImageParser.parse(RawImage(id: session.containerImage, types: [])).label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Status badge
                Text(verbatim: SessionDisplay.localizedStatus(session.status))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
            }

            Divider()

            // Info rows
            VStack(alignment: .leading, spacing: 4) {
                Label(formatTime(session.startedTime), systemImage: "clock")
                Label(formatTime(session.expiresTime), systemImage: "timer")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Resources: given, or in use for a flexible session.
            let resources = SessionDisplay.resources(of: session)
            HStack(spacing: 8) {
                Label("CPU: \(resources.cpu)", systemImage: "cpu")
                Label("RAM: \(resources.ram)", systemImage: "memorychip")
                if let gpu = resources.gpu {
                    // Not `rectangle.stack` — that glyph is the Active
                    // Sessions list header; one symbol, one meaning.
                    Label("GPU: \(gpu)", systemImage: "bolt.fill")
                }
                if resources.inUse {
                    Text("in use")
                }
                Spacer()
                if !session.isFixedResources {
                    Text("FLEX")
                        .font(.system(.caption2, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Divider()

            // Actions — mirrors the CANFAR Science Portal's
            // session-card affordances: clock = renew (extend
            // lifetime), doc = events (K8s view), flag-style
            // open = "go to this session", trash = delete. SF
            // Symbol equivalents in macOS-native flavour, but
            // the visual treatment (circular accent-tint
            // background, filled white icon) intentionally
            // matches the portal so users coming from the web
            // UI recognise the language. Reordered to lead
            // with Open (the most-clicked action on a running
            // session) instead of the portal's clock-first
            // order — the portal puts Renew first because
            // session-extension is a chore the user must opt
            // into; in our app a session is more often opened
            // than renewed.
            // Three cards in a minimum-width window leave ~160pt per card —
            // not enough for four labeled actions. ViewThatFits drops the
            // text labels (icons keep .help + accessibility labels) before
            // the row can compress or clip.
            ViewThatFits(in: .horizontal) {
                actionRow(compact: false)
                actionRow(compact: true)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.platformSeparator, lineWidth: 1)
        )
    }

    // MARK: - Display Helpers

    private var statusColor: Color { SessionDisplay.statusColor(session.status) }
    private var typeColor: Color { SessionDisplay.typeColor(session.sessionType) }
    private var typeImageAsset: String? { SessionDisplay.typeImageAsset(session.sessionType) }
    private var typeIcon: String { SessionDisplay.typeIcon(session.sessionType) }
    private func formatTime(_ s: String) -> String { SessionDisplay.formatTime(s) }

    @ViewBuilder
    private func actionRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            Spacer()
            cardActionButton(
                label: "Open",
                systemImage: "arrow.up.forward.square.fill",
                role: nil,
                enabled: session.isRunning,
                compact: compact,
                help: "Open this session in your browser",
                action: onOpen
            )
            cardActionButton(
                label: "Renew",
                systemImage: "clock.arrow.circlepath",
                role: nil,
                enabled: session.isRunning,
                compact: compact,
                help: "Extend this session's lifetime",
                action: onRenew
            )
            // Each card's Renew and Delete, by session id and by its session's
            // name, so an assistant can point at the one it means (plan 21 N2)
            // and VoiceOver says whose it is.
            .accessibilityLabel(Text("Renew \(session.sessionName)"))
            .pointable("portal.session.\(session.id).renew")
            cardActionButton(
                label: "Events",
                systemImage: "doc.text.fill",
                role: nil,
                enabled: true,
                compact: compact,
                help: "View Kubernetes events and container logs",
                action: onEvents
            )
            .opens("Session Events")
            cardActionButton(
                label: "Delete",
                systemImage: "trash.fill",
                role: .destructive,
                enabled: true,
                compact: compact,
                help: "Stop and delete this session",
                action: onDelete
            )
            .accessibilityLabel(Text("Delete \(session.sessionName)"))
            .pointable("portal.session.\(session.id).delete")
        }
    }

    /// Circular icon-on-tint action button matching the original
    /// CANFAR Science Portal's session-card affordance style.
    /// Filled SF Symbol on a 28pt circular `accent` (or `red`
    /// for destructive) background, with the action label kept
    /// underneath in caption2 — gives users coming from the web
    /// UI the recognisable visual language plus the discoverable
    /// macOS-native text label below. `compact` drops the text
    /// label when the card is too narrow for four labeled actions.
    @ViewBuilder
    private func cardActionButton(
        label: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole?,
        enabled: Bool,
        compact: Bool,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(role == .destructive ? Color.red : Color.accentColor)
                        .frame(width: 26, height: 26)
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                if !compact {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1.0 : 0.4)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(label)
    }
}
