// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The prompt for any assistant, with Copy (plan 52 D2). Whole, selectable
/// text, so a person — or an assistant looking at the screen — reads all
/// of it (D4).
struct AssistantPromptView: View {
    let executable: String

    var body: some View {
        let prompt = AssistantRecipes.prompt(executable: executable)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("A prompt for your assistant").font(.headline)
                Spacer()
                Button("Copy Prompt") { PlatformClipboard.copy(prompt) }
                    .pointable("assistants.prompt.copy")
            }
            Text(prompt)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(prompt))
                .pointable("assistants.prompt")
            Text("Paste it into your assistant's chat. It adds Verbinal to its own settings, then asks you to start a session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Each client's settings for this Mac, with Copy (plan 52 D3).
struct AssistantRecipesList: View {
    let executable: String
    var clients: [AssistantRecipes.Client] = [.codex, .cursor, .geminiCLI, .windsurf, .vsCode]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(clients) { client in
                let recipe = AssistantRecipes.recipe(for: client, executable: executable)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(client.name).font(.headline)
                        Spacer()
                        Button("Copy") { PlatformClipboard.copy(recipe.text) }
                            .controlSize(.small)
                    }
                    if let file = recipe.file {
                        Text(file).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(recipe.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(recipe.text))
                }
                .pointableArea("assistants.recipe.\(client.rawValue)", label: client.name)
            }
            Text("Add it beside the servers already there, then restart or reload the client.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
