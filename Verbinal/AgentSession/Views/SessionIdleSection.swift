// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Settings ▸ AI Agent ▸ Sessions: how long an allowed session lasts
/// without a call (plan 34 S). The person's; an assistant reads it in
/// `describe_app`.
struct SessionIdleSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var approvals = appState.sessionApprovals
        Section {
            Picker("End an idle session after", selection: $approvals.idleMinutes) {
                ForEach(SessionApprovals.idleChoices, id: \.self) { minutes in
                    Text(Self.title(minutes)).tag(minutes)
                }
            }
            .pointable("settings.agent.sessionIdle")
        } header: {
            Text("Sessions")
        } footer: {
            Text("You allow an assistant's session once: when Verbinal restarts, it continues. It ends after this long without a call, and you are asked again when the assistant comes back. End Session, in Session Logs, ends one at once.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 15: String(localized: "15 minutes")
        case 60: String(localized: "1 hour")
        case 240: String(localized: "4 hours")
        case 720: String(localized: "12 hours")
        default: String(localized: "1 day")
        }
    }
}
