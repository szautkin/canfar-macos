// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// Settings ▸ AI Agent ▸ What an assistant may do without asking (plan 30
/// A): a row per kind of change, **Allowed** or **Ask me** — what adds or
/// changes apart from what removes, replaces or stops.
struct ChangePermissionsSection: View {
    @Bindable var agents: AgentsService

    var body: some View {
        Section {
            ForEach(ChangeKind.allCases.filter { !$0.isDestructive }, id: \.self, content: row)
        } header: {
            Text("What an assistant may do without asking")
        } footer: {
            Text("Allowed: an assistant's change of this kind applies at once, with its reason in the session log. Ask me: it waits in Pending until you apply it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Section {
            ForEach(ChangeKind.allCases.filter(\.isDestructive), id: \.self, content: row)
        } header: {
            Text("What removes, replaces or stops")
        } footer: {
            HStack(alignment: .top) {
                Text("What an assistant made is told apart by the session log; what you made never is.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { agents.permissions = .defaults }
                    .controlSize(.small)
                    .disabled(agents.permissions.isDefault)
                    .pointable("settings.agent.permissions.defaults")
            }
        }
    }

    @ViewBuilder
    private func row(_ kind: ChangeKind) -> some View {
        LabeledContent {
            if kind.isSettable {
                Picker(LocalizedStringKey(kind.title), selection: allowed(kind)) {
                    Text("Allowed").tag(true)
                    Text("Ask me").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } else {
                Text("Always asks")
                    .foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(kind.title))
                Text(LocalizedStringKey(kind.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .pointable("settings.agent.permission.\(kind.rawValue)")
    }

    private func allowed(_ kind: ChangeKind) -> Binding<Bool> {
        Binding(get: { agents.permissions.allows(kind) },
                set: { agents.permissions.set(kind, allowed: $0) })
    }
}
