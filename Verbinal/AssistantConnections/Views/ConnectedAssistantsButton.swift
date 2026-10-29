// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// "2 assistants" beside the activity bar, while any is connected (plan 52
/// C4); a click lists them, each with Close.
struct ConnectedAssistantsButton: View {
    @Environment(AppState.self) private var appState
    @State private var showList = false

    var body: some View {
        let count = appState.assistantConnections.connections.count
        if count > 0 {
            Button { showList.toggle() } label: {
                Label(String(localized: "\(count) assistants"), image: "robot")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("The assistants connected now")
            .pointable("activity.assistants", opens: "Connected Assistants")
            .uiPresented("Connected Assistants", .popover, isPresented: $showList)
            .popover(isPresented: $showList, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connected Assistants").font(.headline)
                    ConnectedAssistantsList()
                }
                .padding(12)
                .frame(width: 380)
            }
        }
    }
}
