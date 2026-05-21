// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// Small wand icon shown next to entries that originated from an
/// MCP-connected AI agent. Hover/click reveals a popover with the
/// fields stamped on the entity at apply time:
///
///   * Agent label    (e.g. `claude-ai/0.1.0`)
///   * Origin fingerprint (6-char SHA prefix, stable per client)
///   * Applied timestamp (relative + absolute)
///   * Original proposal summary (the same one-liner that showed in
///     the strip preview before the user clicked Apply)
///   * Proposal id (UUID)
///
/// One small icon, one consistent colour, one consistent affordance —
/// the user's eye learns it instantly. No badge → user authored;
/// with badge → an AI proposed and the user accepted.
struct AgentAttributionBadge: View {
    let attribution: AgentAttribution
    @State private var isHovering = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "wand.and.rays")
                .font(.caption2)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .help("Created by \(attribution.originLabel)")
        .accessibilityLabel("Created by \(attribution.originLabel)")
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            AgentAttributionPopover(attribution: attribution)
        }
    }
}

private struct AgentAttributionPopover: View {
    let attribution: AgentAttribution

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.rays")
                    .foregroundStyle(.tint)
                Text("Created by AI agent")
                    .font(.callout.bold())
            }
            Divider()
            row("Agent",   attribution.originLabel,         monospaced: true)
            row("Client",  attribution.originFingerprint,   monospaced: true)
            row("Applied", absoluteAndRelative(attribution.appliedAt))
            row("From proposal", attribution.proposalID.uuidString.prefix(8) + "…", monospaced: true)
            Divider()
            Text("Summary")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(attribution.summary)
                .font(.caption)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(minWidth: 320, idealWidth: 360)
    }

    private func row(_ label: String, _ value: some StringProtocol, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            if monospaced {
                Text(value).font(.caption.monospaced()).textSelection(.enabled)
            } else {
                Text(value).font(.caption).textSelection(.enabled)
            }
        }
    }

    private func absoluteAndRelative(_ date: Date) -> String {
        let abs = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        let rel = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return "\(abs) (\(rel))"
    }
}
