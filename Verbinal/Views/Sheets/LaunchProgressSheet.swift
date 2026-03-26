// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
        .frame(width: 380)
    }
}
