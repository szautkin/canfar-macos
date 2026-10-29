// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Each connected assistant, with Close (plan 52 C1, C2): the one list
/// Settings ▸ AI Agent and the activity bar both show.
struct ConnectedAssistantsList: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let approvals = appState.sessionApprovals
        let list = appState.assistantConnections
        // Redrawn every 30 s, so "the last 2 min ago" stays true.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                ForEach(list.connections) { connection in
                    AssistantConnectionRow(
                        summary: AssistantConnectionSummary(
                            connection, session: approvals.keptState(of: connection.session),
                            asking: approvals.pending.first { $0.id == connection.session },
                            appVersion: AgentsService.serverIdentity.version, now: context.date),
                        close: { Task { await list.close(connection.session) } })
                }
            }
        }
    }
}

/// One assistant: who, its session, its bridge, its calls, what deserves a
/// look, and Close.
struct AssistantConnectionRow: View {
    let summary: AssistantConnectionSummary
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.headline)
                Text(summary.session).font(.callout)
                if let bridge = summary.bridge {
                    Text(bridge).font(.caption).foregroundStyle(.secondary)
                }
                Text(summary.calls).font(.caption).foregroundStyle(.secondary)
                ForEach(summary.marks, id: \.text) { mark in
                    Label(mark.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if summary.canClose {
                Button("Close", action: close)
                    .help("Ends its session and its bridge: its app shows the Verbinal server ended.")
            }
        }
        .pointableItem(summary.title)
    }
}
