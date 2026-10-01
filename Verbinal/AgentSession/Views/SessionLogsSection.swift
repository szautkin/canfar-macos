// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Settings ▸ AI Agent ▸ Session Logs: the way in to every assistant
/// session's log (plan 23 L4). Shown whether or not the server runs — the
/// logs of past sessions stay readable.
struct SessionLogsSection: View {
    @Environment(AppState.self) private var appState
    @State private var sessionLogs: SessionLogsModel?

    var body: some View {
        Section {
            Button("Show Session Logs…") {
                guard let hub = appState.sessionLog else { return }
                sessionLogs = SessionLogsModel(query: SessionLogQuery(store: hub.store, hub: hub))
            }
            .disabled(appState.sessionLog == nil)
            .pointable("settings.agent.sessionLogs")
            .sheet(item: $sessionLogs) { SessionLogsView(model: $0) }
        } header: {
            Text("Session Logs")
        } footer: {
            Text("A log of each assistant's session: everything that happened while it was connected — each change, who made it and why, the app's decisions, failures and what they mean. Kept 10 days, and 10 MB in all; the assistant reads it with get_session_log.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
