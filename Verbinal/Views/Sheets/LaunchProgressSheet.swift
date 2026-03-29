// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct LaunchProgressSheet: View {
    @Bindable var model: SessionLaunchModel
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if model.isLaunching {
                ProgressView()
                    .scaleEffect(1.5)
                Text(model.launchStatus)
                    .font(.body)
            } else if model.launchSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Session launched successfully!")
                    .font(.headline)
                Text(model.launchStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.hasError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text("Launch Failed")
                    .font(.headline)
                Text(model.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !model.isLaunching {
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .sheetFrame(width: 380)
    }
}
