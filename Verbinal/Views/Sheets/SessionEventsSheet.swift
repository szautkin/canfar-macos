// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SessionEventsSheet: View {
    let title: String
    let events: String
    let logs: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    private var currentContent: String {
        selectedTab == 0 ? events : logs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Events / Logs: \(title)")
                .font(.title3)
                .fontWeight(.semibold)

            Picker("", selection: $selectedTab) {
                Text("Events").tag(0)
                Text("Logs").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                Text(currentContent)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.textFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Copy") {
                    PlatformClipboard.copy(currentContent)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .sheetFrame(minWidth: 600, minHeight: 450)
    }
}
