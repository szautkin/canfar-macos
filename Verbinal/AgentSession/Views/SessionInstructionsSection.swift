// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Settings ▸ AI Agent ▸ Session Instructions: what every assistant
/// session's window starts from (plan 25 S).
struct SessionInstructionsSection: View {
    @Environment(AppState.self) private var appState
    @State private var text = ""

    private var words: Int { SessionApprovals.words(text) }

    var body: some View {
        Section {
            TextEditor(text: $text)
                .textEditorName(String(localized: "Session Instructions"))
                .font(.callout)
                .frame(minHeight: 80)
                .onChange(of: text) { _, new in
                    if SessionApprovals.words(new) <= SessionApprovals.maxWords {
                        appState.sessionApprovals.defaultInstructions = new
                    }
                }
            HStack {
                Text("\(words) of \(SessionApprovals.maxWords) words")
                    .foregroundStyle(words > SessionApprovals.maxWords ? .red : .secondary)
                Spacer()
                Button("Reset") { text = SessionApprovals.builtInInstructions }
                    .disabled(text == SessionApprovals.builtInInstructions)
            }
            .font(.caption)
        } header: {
            Text("Session Instructions")
        } footer: {
            Text("An assistant starts each session with start_session, and you allow it in a window that shows who it is. These instructions fill that window; you can change them there for one session. The assistant is told to follow them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear { text = appState.sessionApprovals.defaultInstructions }
    }
}
