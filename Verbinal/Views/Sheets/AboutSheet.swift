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

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)

            Text("Verbinal")
                .font(.title)
                .fontWeight(.bold)

            Text("A CANFAR Science Portal Companion")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Version 1.0.0")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("Verbinal provides a native desktop interface for managing")
                Text("interactive computing sessions on the CANFAR platform.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Link("Visit canfar.net", destination: URL(string: "https://www.canfar.net")!)
                .font(.caption)

            Divider()
                .frame(width: 200)

            Text("\u{00A9} 2025 Serhii Zautkin")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 400)
    }
}
