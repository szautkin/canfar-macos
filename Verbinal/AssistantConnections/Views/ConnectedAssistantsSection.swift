// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Settings ▸ AI Agent ▸ Connected Assistants (plan 52 C4): who is
/// connected now, each with Close, or how to connect one.
struct ConnectedAssistantsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let list = appState.assistantConnections
        Section {
            if list.connections.isEmpty {
                Text("No assistant is connected.")
                    .foregroundStyle(.secondary)
                AssistantPromptView(executable: appState.mcpIntegrationSettings.executablePath())
            } else {
                ConnectedAssistantsList()
                if list.connections.count > 1 {
                    Button("Close All") { Task { await list.closeAll() } }
                        .pointable("settings.agent.closeAllAssistants")
                }
            }
        } header: {
            Text("Connected Assistants")
        } footer: {
            Text("Each assistant's app runs a small bridge to Verbinal. Close ends the assistant's session and its bridge, and its app shows the Verbinal server ended; turning off Allow external AI agents closes them all. If an app starts its bridge again, quit that app, or remove Verbinal from its settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .pointableArea("settings.agent.connectedAssistants", label: String(localized: "Connected Assistants"))
    }
}
