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
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentContent, forType: .string)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 450)
    }
}
