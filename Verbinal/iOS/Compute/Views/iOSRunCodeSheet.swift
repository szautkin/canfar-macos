// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Code to run on the person's compute session, as theirs (plan 47 2.4) —
/// the same way the Mac's Run Code box sends it.
struct iOSRunCodeSheet: View {
    @Bindable var model: RemoteComputeModel
    var onSent: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isEmpty: Bool { model.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Language", selection: $model.language) {
                        ForEach(RunCodeContract.supportedLanguages, id: \.self) { language in
                            Text(language.capitalized).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Spacer()
                    Stepper("Timeout: \(model.timeoutSeconds) s", value: $model.timeoutSeconds,
                            in: 10...RunCodeContract.maxTimeoutSeconds, step: 10)
                        .fixedSize()
                        .font(.callout)
                }
                CodeEditor(text: $model.code)
                    .frame(minHeight: 220)
                Text("It runs as you, on your session — the same way run_code runs your assistant's code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.isConfigured {
                    Label("Set an image in the menu's AI Compute first.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding()
            .navigationTitle("Run Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") {
                        Task {
                            await model.runSnippet()
                            onSent()
                        }
                        dismiss()
                    }
                    .disabled(isEmpty || !model.canRun)
                }
            }
        }
        .iosSheetChrome()
    }
}
