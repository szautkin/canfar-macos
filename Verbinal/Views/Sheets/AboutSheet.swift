// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("Verbinal provides a native interface for managing")
                Text("interactive computing sessions on the CANFAR platform.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Text(platformVersionString)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let url = URL(string: "https://www.canfar.net") {
                Link("Visit canfar.net", destination: url)
                    .font(.caption)
            }

            Divider()
                .frame(width: 200)

            Text("\u{00A9} 2026 Serhii Zautkin")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .sheetFrame(width: 400)
    }

    private var platformVersionString: String {
        #if os(macOS)
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #endif
    }
}
